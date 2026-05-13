"""JWT issuing/verification and refresh-token rotation with reuse detection.

Access tokens are short-lived (configurable, default 15 min) and stateless —
they encode `sub`, `email`, `exp`, `iat`, `jti`, `type=access`.

Refresh tokens are long-lived (default 30 days) and DB-backed: every issued
refresh JTI is stored in `refresh_tokens`. Presenting a token already marked
as `rotated_at` indicates token theft and triggers revocation of the whole
family — see `rotate_refresh`. This is the OAuth 2.0 refresh-token rotation
pattern recommended by RFC 6819 / OWASP.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

from jose import jwt
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.config import Settings
from kp_api.domain.models import RefreshToken, User

JWT_ALGORITHM = "HS256"
ACCESS_TOKEN_TYPE = "access"
REFRESH_TOKEN_TYPE = "refresh"


class AuthError(Exception):
    """Raised on any auth-layer failure. Translated to HTTP 401 at the API boundary."""


@dataclass(frozen=True)
class AccessClaims:
    sub: UUID
    email: str
    jti: UUID
    exp: datetime


@dataclass(frozen=True)
class TokenPair:
    access_token: str
    access_expires_at: datetime
    refresh_token: str
    refresh_expires_at: datetime


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _encode(payload: dict[str, object], secret: str) -> str:
    return jwt.encode(payload, secret, algorithm=JWT_ALGORITHM)


def _decode(token: str, secret: str) -> dict[str, object]:
    try:
        return jwt.decode(token, secret, algorithms=[JWT_ALGORITHM])
    except jwt.JWTError as exc:
        raise AuthError("invalid token") from exc


def _issue_access(user: User, settings: Settings) -> tuple[str, datetime, UUID]:
    now = _utcnow()
    exp = now + timedelta(seconds=settings.api_jwt_access_ttl_seconds)
    jti = uuid4()
    payload = {
        "sub": str(user.id),
        "email": user.email,
        "type": ACCESS_TOKEN_TYPE,
        "iat": int(now.timestamp()),
        "exp": int(exp.timestamp()),
        "jti": str(jti),
    }
    return _encode(payload, settings.api_jwt_secret), exp, jti


def _issue_refresh(
    user: User,
    settings: Settings,
    family_id: UUID,
    parent_jti: UUID | None,
) -> tuple[str, datetime, UUID]:
    now = _utcnow()
    exp = now + timedelta(seconds=settings.api_jwt_refresh_ttl_seconds)
    jti = uuid4()
    payload = {
        "sub": str(user.id),
        "type": REFRESH_TOKEN_TYPE,
        "family": str(family_id),
        "iat": int(now.timestamp()),
        "exp": int(exp.timestamp()),
        "jti": str(jti),
    }
    _ = parent_jti  # not encoded into the token; only used for DB linkage
    return _encode(payload, settings.api_jwt_secret), exp, jti


async def issue_tokens_for_user(
    session: AsyncSession, user: User, settings: Settings
) -> TokenPair:
    """Issue a fresh access + refresh pair at the start of a new login."""

    access, access_exp, _ = _issue_access(user, settings)
    family_id = uuid4()
    refresh, refresh_exp, refresh_jti = _issue_refresh(
        user, settings, family_id=family_id, parent_jti=None
    )
    session.add(
        RefreshToken(
            jti=refresh_jti,
            user_id=user.id,
            family_id=family_id,
            parent_jti=None,
            expires_at=refresh_exp,
        )
    )
    await session.flush()
    return TokenPair(
        access_token=access,
        access_expires_at=access_exp,
        refresh_token=refresh,
        refresh_expires_at=refresh_exp,
    )


def decode_access(token: str, settings: Settings) -> AccessClaims:
    payload = _decode(token, settings.api_jwt_secret)
    if payload.get("type") != ACCESS_TOKEN_TYPE:
        raise AuthError("wrong token type")
    try:
        return AccessClaims(
            sub=UUID(str(payload["sub"])),
            email=str(payload["email"]),
            jti=UUID(str(payload["jti"])),
            exp=datetime.fromtimestamp(int(payload["exp"]), tz=timezone.utc),
        )
    except (KeyError, ValueError) as exc:
        raise AuthError("malformed token") from exc


async def rotate_refresh(
    session: AsyncSession, token: str, settings: Settings
) -> TokenPair:
    """Validate the incoming refresh token, detect reuse, and issue a new pair.

    Reuse detection: if the presented token's DB row already has `rotated_at`
    set, an earlier rotation already consumed it — this means an attacker has
    a stale copy. Revoke the entire family and reject the request.
    """

    payload = _decode(token, settings.api_jwt_secret)
    if payload.get("type") != REFRESH_TOKEN_TYPE:
        raise AuthError("wrong token type")
    try:
        jti = UUID(str(payload["jti"]))
        family_id = UUID(str(payload["family"]))
        user_id = UUID(str(payload["sub"]))
    except (KeyError, ValueError) as exc:
        raise AuthError("malformed token") from exc

    row = await session.scalar(
        select(RefreshToken).where(RefreshToken.jti == jti).with_for_update()
    )
    if row is None or row.family_id != family_id or row.user_id != user_id:
        raise AuthError("unknown refresh token")
    if row.revoked_at is not None:
        raise AuthError("refresh revoked")
    if row.expires_at < _utcnow():
        raise AuthError("refresh expired")
    if row.rotated_at is not None:
        # Reuse — burn the entire family.
        await session.execute(
            update(RefreshToken)
            .where(RefreshToken.family_id == family_id)
            .values(revoked_at=_utcnow())
        )
        await session.flush()
        raise AuthError("refresh reuse detected")

    user = await session.get(User, user_id)
    if user is None:
        raise AuthError("user missing")

    access, access_exp, _ = _issue_access(user, settings)
    refresh, refresh_exp, refresh_jti = _issue_refresh(
        user, settings, family_id=family_id, parent_jti=jti
    )
    row.rotated_at = _utcnow()
    session.add(
        RefreshToken(
            jti=refresh_jti,
            user_id=user.id,
            family_id=family_id,
            parent_jti=jti,
            expires_at=refresh_exp,
        )
    )
    await session.flush()
    return TokenPair(
        access_token=access,
        access_expires_at=access_exp,
        refresh_token=refresh,
        refresh_expires_at=refresh_exp,
    )


async def revoke_family(session: AsyncSession, refresh_token: str, settings: Settings) -> None:
    """Manual logout: revoke the entire family the presented refresh belongs to."""

    payload = _decode(refresh_token, settings.api_jwt_secret)
    try:
        family_id = UUID(str(payload["family"]))
    except (KeyError, ValueError) as exc:
        raise AuthError("malformed token") from exc
    await session.execute(
        update(RefreshToken)
        .where(RefreshToken.family_id == family_id)
        .values(revoked_at=_utcnow())
    )
    await session.flush()
