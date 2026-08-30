"""Spotify access tokens for the planner's in-page player.

The planner plays a concert's programme itself (Web Playback SDK), which
needs a user access token with the `streaming` scope. The **refresh** token
is Petr's, minted once by hand and kept in the server's environment — the
browser never sees it and no login flow lives in the login-less SPA.

What the browser does get is a short-lived access token, so the blast radius
of the LAN-trusted planner is one hour of Spotify API access rather than a
permanent grant. Tokens are cached in memory until shortly before they
expire; Spotify hands out the same token for repeated refreshes anyway.
"""

from __future__ import annotations

import logging
import time

import httpx
from pydantic import BaseModel

logger = logging.getLogger(__name__)

_ACCOUNTS_URL = "https://accounts.spotify.com/api/token"
_REQUEST_TIMEOUT = httpx.Timeout(10.0)
# Refresh a little before expiry so a page that just got a token can still
# finish its handshake with it.
_EXPIRY_MARGIN_SECONDS = 60

_cache: tuple[float, str, int] | None = None


class SpotifyToken(BaseModel):
    """What the SPA needs to build a player: the token and its lifetime."""

    access_token: str
    expires_in: int


class SpotifyUnavailable(RuntimeError):
    """No credentials configured, or Spotify refused the refresh."""


def reset_cache() -> None:
    """Test hook — drops the memoized token."""

    global _cache
    _cache = None


async def access_token(
    client_id: str,
    client_secret: str,
    refresh_token: str,
    *,
    client: httpx.AsyncClient | None = None,
) -> SpotifyToken:
    """A user access token, from the stored refresh token.

    Raises `SpotifyUnavailable` when Spotify is unreachable or the grant was
    rejected (a revoked or re-scoped refresh token) — the planner then falls
    back to opening tracks on Spotify instead of playing them.
    """

    global _cache

    if not client_id or not client_secret or not refresh_token:
        raise SpotifyUnavailable("spotify credentials not configured")

    now = time.monotonic()
    if _cache is not None and now < _cache[0]:
        return SpotifyToken(access_token=_cache[1], expires_in=int(_cache[0] - now))

    owns_client = client is None
    http = client or httpx.AsyncClient(timeout=_REQUEST_TIMEOUT)
    try:
        response = await http.post(
            _ACCOUNTS_URL,
            auth=(client_id, client_secret),
            data={"grant_type": "refresh_token", "refresh_token": refresh_token},
        )
    except Exception as exc:  # network, DNS, TLS…
        logger.warning("Spotify token refresh failed", exc_info=True)
        raise SpotifyUnavailable("spotify unreachable") from exc
    finally:
        if owns_client:
            await http.aclose()

    if response.status_code != 200:
        # Deliberately no body: it echoes the client id back.
        logger.warning("Spotify token refresh rejected with %s", response.status_code)
        raise SpotifyUnavailable("spotify rejected the refresh token")

    body = response.json()
    token = body.get("access_token")
    expires_in = int(body.get("expires_in", 3600))
    if not isinstance(token, str) or not token:
        raise SpotifyUnavailable("spotify returned no access token")

    _cache = (now + max(expires_in - _EXPIRY_MARGIN_SECONDS, 0), token, expires_in)
    return SpotifyToken(access_token=token, expires_in=expires_in)
