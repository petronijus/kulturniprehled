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
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

from jose import jwt
from jose.exceptions import JWTError
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.config import Settings
from kp_api.domain.models import PersonalAccessToken, RefreshToken, User
from kp_api.domain.scopes import format_scopes

JWT_ALGORITHM = "HS256"
ACCESS_TOKEN_TYPE = "access"  # noqa: S105 (JWT type tag, not a secret)
REFRESH_TOKEN_TYPE = "refresh"  # noqa: S105 (JWT type tag, not a secret)
PAT_TOKEN_TYPE = "pat"  # noqa: S105 (JWT type tag, not a secret)


class AuthError(Exception):
    """Raised on any auth-layer failure. Translated to HTTP 401 at the API boundary."""


@dataclass(frozen=True)
class AccessClaims:
    sub: UUID
    email: str
    jti: UUID
    exp: datetime


@dataclass(frozen=True)
class BearerClaims:
    """Either a short-lived access JWT or a long-lived PAT.

    `is_pat` lets the auth dependency switch on whether to check the DB for
    revocation. Access JWTs are stateless and rely on their short expiry."""

    sub: UUID
    email: str
    jti: UUID
    is_pat: bool


@dataclass(frozen=True)
class TokenPair:
    access_token: str
    access_expires_at: datetime
    refresh_token: str
    refresh_expires_at: datetime


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _encode(payload: dict[str, object], secret: str) -> str:
    return jwt.encode(payload, secret, algorithm=JWT_ALGORITHM)


def _decode(token: str, secret: str) -> dict[str, object]:
    try:
        return jwt.decode(token, secret, algorithms=[JWT_ALGORITHM])
    except JWTError as exc:
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


async def issue_tokens_for_user(session: AsyncSession, user: User, settings: Settings) -> TokenPair:
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
            exp=datetime.fromtimestamp(int(str(payload["exp"])), tz=UTC),
        )
    except (KeyError, ValueError) as exc:
        raise AuthError("malformed token") from exc


def decode_bearer(token: str, settings: Settings) -> BearerClaims:
    """Decode either an access JWT or a PAT.

    Both share the same signing key. PATs do not include `exp` and do not
    rotate; the API caller must consult `personal_access_tokens` to ensure
    the row exists and is not revoked."""

    payload = _decode(token, settings.api_jwt_secret)
    token_type = payload.get("type")
    if token_type not in (ACCESS_TOKEN_TYPE, PAT_TOKEN_TYPE):
        raise AuthError("wrong token type")
    try:
        return BearerClaims(
            sub=UUID(str(payload["sub"])),
            email=str(payload["email"]),
            jti=UUID(str(payload["jti"])),
            is_pat=token_type == PAT_TOKEN_TYPE,
        )
    except (KeyError, ValueError) as exc:
        raise AuthError("malformed token") from exc


async def mint_pat(
    session: AsyncSession,
    user: User,
    name: str,
    settings: Settings,
    expires_at: datetime | None = None,
    scopes: list[str] | None = None,
) -> str:
    """Issue a long-lived bearer JWT and record the row for revocation.

    Returns the encoded JWT — callers must show it to the user **once** and
    never store the plaintext server-side. The DB row holds the `jti`, a
    human-readable `name`, and optional `scopes` for audit and authorization,
    never the token itself. `scopes=None` mints an unrestricted token (acts as
    the full user); a list restricts it to endpoints declaring one of those
    scopes — the source of truth is the DB row, not the JWT, so scope is never
    trusted from the presented token."""

    now = _utcnow()
    jti = uuid4()
    payload: dict[str, object] = {
        "sub": str(user.id),
        "email": user.email,
        "type": PAT_TOKEN_TYPE,
        "iat": int(now.timestamp()),
        "jti": str(jti),
    }
    if expires_at is not None:
        payload["exp"] = int(expires_at.timestamp())
    token = _encode(payload, settings.api_jwt_secret)
    session.add(
        PersonalAccessToken(
            jti=jti,
            user_id=user.id,
            name=name,
            expires_at=expires_at,
            scopes=format_scopes(scopes),
        )
    )
    await session.flush()
    return token


async def touch_pat(session: AsyncSession, jti: UUID) -> PersonalAccessToken | None:
    """Look up a PAT and persist `last_used_at`.

    Returns None when the token is unknown, revoked or expired so the caller
    can answer 401 in one place. The update is committed here so the audit
    record sticks even for read-only requests (those endpoints never commit
    themselves)."""

    row = await session.get(PersonalAccessToken, jti)
    if row is None or row.revoked_at is not None:
        return None
    now = _utcnow()
    if row.expires_at is not None and row.expires_at < now:
        return None
    await session.execute(
        update(PersonalAccessToken).where(PersonalAccessToken.jti == jti).values(last_used_at=now)
    )
    await session.commit()
    row.last_used_at = now
    return row


async def revoke_pat(session: AsyncSession, jti: UUID) -> None:
    row = await session.get(PersonalAccessToken, jti)
    if row is not None and row.revoked_at is None:
        row.revoked_at = _utcnow()
        await session.flush()


async def rotate_refresh(session: AsyncSession, token: str, settings: Settings) -> TokenPair:
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
        update(RefreshToken).where(RefreshToken.family_id == family_id).values(revoked_at=_utcnow())
    )
    await session.flush()
