"""FastAPI dependencies shared across routers."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, Header, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.auth import AuthError, decode_bearer, touch_pat
from kp_api.adapters.db import get_session
from kp_api.config import Settings, get_settings
from kp_api.domain.enums import UserRole
from kp_api.domain.models import User, WorkspaceMember
from kp_api.domain.scopes import SCOPE_SEASON_READ, SCOPE_SEASON_WRITE, parse_scopes

SessionDep = Annotated[AsyncSession, Depends(get_session)]
SettingsDep = Annotated[Settings, Depends(get_settings)]


@dataclass(frozen=True)
class AuthContext:
    """The authenticated principal plus its capability scopes.

    `scopes is None` means an unrestricted credential (an interactive access
    JWT, or a PAT minted without scopes) that may use any endpoint. A non-None
    set is a scope-restricted PAT: default-denied everywhere except endpoints
    that declare one of its scopes via `require_scope`."""

    user: User
    scopes: frozenset[str] | None


async def _trusted_lan_context(session: AsyncSession) -> AuthContext:
    """Anonymous home-network principal: the workspace owner, restricted to
    the season scopes.

    Used by the login-less planner SPA. Trust comes from the network path
    (see `get_auth_context`): the Cloudflare Tunnel is the only public way
    to reach this process, and tunneled requests always carry
    `CF-Connecting-IP` — so a header-less direct request can only originate
    on the LAN / tailnet. The scope restriction keeps the blast radius to
    the season surface; general endpoints default-deny scoped principals.
    """

    owner = await session.scalar(
        select(User)
        .join(WorkspaceMember, WorkspaceMember.user_id == User.id)
        .where(WorkspaceMember.role == UserRole.OWNER)
        .order_by(User.created_at.asc())
        .limit(1)
    )
    if owner is None:
        # Deployments bootstrapped before owner assignment was made
        # deterministic may lack an OWNER membership row — fall back to
        # the earliest member (single-household reality: that is Petr).
        owner = await session.scalar(
            select(User)
            .join(WorkspaceMember, WorkspaceMember.user_id == User.id)
            .order_by(User.created_at.asc())
            .limit(1)
        )
    if owner is None:
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            "trusted-lan auth needs a bootstrapped workspace owner",
        )
    return AuthContext(user=owner, scopes=frozenset({SCOPE_SEASON_READ, SCOPE_SEASON_WRITE}))


async def get_auth_context(
    request: Request,
    session: SessionDep,
    settings: SettingsDep,
    authorization: Annotated[str | None, Header()] = None,
) -> AuthContext:
    if not authorization or not authorization.lower().startswith("bearer "):
        came_through_cloudflare = "cf-connecting-ip" in request.headers
        if settings.web_trusted_lan and not authorization and not came_through_cloudflare:
            return await _trusted_lan_context(session)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    try:
        claims = decode_bearer(token, settings)
    except AuthError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, str(exc)) from exc

    scopes: frozenset[str] | None = None
    if claims.is_pat:
        # PATs are DB-tracked: revocation, expiry, scopes, and last_used_at all
        # live there. Touch the row so we have a real "last seen" without paying
        # for a separate audit table — and read scopes from the row, never from
        # the token, so the DB stays authoritative.
        row = await touch_pat(session, claims.jti)
        if row is None:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "pat revoked or unknown")
        scopes = parse_scopes(row.scopes)

    user = await session.get(User, claims.sub)
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "user not found")
    return AuthContext(user=user, scopes=scopes)


AuthContextDep = Annotated[AuthContext, Depends(get_auth_context)]


async def get_current_user(ctx: AuthContextDep) -> User:
    """Default principal dependency for general endpoints.

    Rejects scope-restricted tokens outright: a token carrying explicit scopes
    may only reach endpoints that opt in via `require_scope`. This is what
    makes scoping default-deny — a `digest:read` token cannot fall back to the
    general `/v1/events` surface."""

    if ctx.scopes is not None:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            "token is scope-restricted and not permitted on this endpoint",
        )
    return ctx.user


CurrentUser = Annotated[User, Depends(get_current_user)]


def require_scope(scope: str) -> Callable[[AuthContext], Awaitable[User]]:
    """Build a dependency that admits unrestricted credentials and scoped
    tokens holding `scope`, and rejects everything else with 403."""

    async def _dep(ctx: AuthContextDep) -> User:
        if ctx.scopes is not None and scope not in ctx.scopes:
            raise HTTPException(
                status.HTTP_403_FORBIDDEN,
                f"missing required scope: {scope}",
            )
        return ctx.user

    return _dep
