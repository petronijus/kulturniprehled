"""FastAPI dependencies shared across routers."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.auth import AuthError, decode_bearer, touch_pat
from kp_api.adapters.db import get_session
from kp_api.config import Settings, get_settings
from kp_api.domain.models import User
from kp_api.domain.scopes import parse_scopes

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


async def get_auth_context(
    session: SessionDep,
    settings: SettingsDep,
    authorization: Annotated[str | None, Header()] = None,
) -> AuthContext:
    if not authorization or not authorization.lower().startswith("bearer "):
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
