"""Cross-cutting hardening: structured logging, security headers, rate limiter.

Wired into [main.create_app] so every route gets the security headers and
the auth endpoints can decorate with `@limiter.limit(...)`. Anything that
wants to emit a structured event imports `auth_logger` (or calls
`structlog.get_logger("kp_api.<area>")`) — the JSON renderer puts each
event on its own line in stderr, which `docker compose logs api` picks up
unchanged so a grep / jq pipeline can audit sign-in attempts later.
"""

from __future__ import annotations

import logging
import sys
from collections.abc import Awaitable, Callable

import structlog
from slowapi import Limiter
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response
from starlette.types import ASGIApp

from kp_api.config import Settings


def configure_logging(settings: Settings) -> None:
    """Set up structlog with JSON output to stderr.

    Idempotent: safe to call multiple times (e.g. in test fixtures).
    """

    level_name = (settings.log_level or "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)
    logging.basicConfig(
        format="%(message)s",
        stream=sys.stderr,
        level=level,
        force=True,
    )
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso", utc=True),
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(level),
        cache_logger_on_first_use=True,
    )


# Lazy module-level loggers — `configure_logging` must run first for these
# to emit anything sensible.
auth_logger = structlog.get_logger("kp_api.auth")


def real_client_ip(request: Request) -> str:
    """Return the originating client IP, accounting for Cloudflare.

    Order of trust:
      1. `CF-Connecting-IP` — Cloudflare's authoritative end-user IP,
         set by the tunnel that fronts the API in prod.
      2. First entry of `X-Forwarded-For` — fallback for non-CF proxies.
      3. The direct socket peer — works in dev (no proxy).

    Only safe because every public hop goes through Cloudflare; if the
    API were ever exposed directly to the internet the first two
    headers could be spoofed.
    """

    cf = request.headers.get("cf-connecting-ip")
    if cf:
        return cf.strip()
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",", 1)[0].strip()
    if request.client is not None:
        return request.client.host
    return "unknown"


# Module-level limiter so `auth.py` can `@limiter.limit(...)` decorate
# routes at import time. `configure_limiter` lets `main.create_app`
# flip `enabled` based on runtime Settings — important so the
# `RATE_LIMIT_ENABLED=false` override in test conftest actually takes
# effect. The per-route limit strings live next to their endpoints
# (auth.py), the catch-all default below caps general traffic.
limiter = Limiter(
    key_func=real_client_ip,
    enabled=True,
    default_limits=["120/minute"],
    headers_enabled=False,
)


def configure_limiter(settings: Settings) -> None:
    """Apply runtime settings to the module-level limiter."""

    limiter.enabled = settings.rate_limit_enabled


# Three policies, keyed by path.
#
# The planner itself stays pure same-origin: its only foreign content is the
# player frame below, which is served from here, so `frame-src 'self'`.
#
# That frame (`/app/player.html`) is the one place Spotify's Web Playback
# SDK runs. It evaluates code at runtime, streams encrypted audio and talks
# to Spotify's API and websockets, so its document needs `'unsafe-eval'`
# plus Spotify's hosts — a relaxation kept off the planner by giving the
# player a page of its own that holds no application data and renders
# nothing at all.
_SPOTIFY_SDK = "https://sdk.scdn.co"
_SPOTIFY_API = "https://api.spotify.com"
_SPOTIFY_HOSTS = "https://*.spotify.com https://*.scdn.co wss://*.spotify.com"
_SPA_CSP = (
    "default-src 'self'; "
    "img-src 'self' data:; "
    "style-src 'self'; "
    "script-src 'self'; "
    "connect-src 'self'; "
    "frame-src 'self'; "
    "frame-ancestors 'none'; "
    "base-uri 'none'"
)
_PLAYER_CSP = (
    "default-src 'self'; "
    "img-src 'self' data: https://*.scdn.co; "
    "style-src 'self' 'unsafe-inline'; "
    f"script-src 'self' 'unsafe-eval' {_SPOTIFY_SDK}; "
    f"connect-src 'self' {_SPOTIFY_API} {_SPOTIFY_HOSTS}; "
    f"media-src blob: {_SPOTIFY_HOSTS}; "
    "worker-src 'self' blob:; "
    "frame-ancestors 'self'; "
    "base-uri 'none'"
)

_API_CSP = "default-src 'none'; frame-ancestors 'none'"


class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    """Attach hardening headers to every response.

    These are mostly relevant for browsers, but a misconfigured client
    or an attacker-driven embed can hit the API too — the headers are
    cheap and the floor is "no worse than no header".

    Path-aware CSP: the SPA mount at `/app` gets a same-origin policy, its
    player frame (`/app/player.html`) the one relaxed policy Spotify's embed
    API needs, and the JSON surface keeps the deny-everything policy.
    """

    def __init__(self, app: ASGIApp) -> None:
        super().__init__(app)

    async def dispatch(
        self,
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        response: Response = await call_next(request)
        response.headers.setdefault(
            "Strict-Transport-Security",
            "max-age=31536000; includeSubDomains",
        )
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        path = request.url.path
        is_spa = path == "/app" or path.startswith("/app/")
        is_player = path == "/app/player.html"
        if is_player:
            policy = _PLAYER_CSP
        elif is_spa:
            policy = _SPA_CSP
        else:
            policy = _API_CSP
        response.headers.setdefault("Content-Security-Policy", policy)
        # The planner frames the player; X-Frame-Options: DENY would win over
        # the CSP's `frame-ancestors 'self'` in browsers that honour both.
        if is_player:
            response.headers["X-Frame-Options"] = "SAMEORIGIN"
        return response


__all__ = [
    "SecurityHeadersMiddleware",
    "auth_logger",
    "configure_limiter",
    "configure_logging",
    "limiter",
    "real_client_ip",
]
