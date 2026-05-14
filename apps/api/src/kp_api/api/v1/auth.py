"""Google OAuth + JWT auth endpoints."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.auth import (
    AuthError,
    TokenPair,
    issue_tokens_for_user,
    revoke_family,
    rotate_refresh,
)
from kp_api.adapters.db import get_session
from kp_api.adapters.oauth import GoogleIdTokenVerifier, IdTokenVerifier, OAuthError
from kp_api.config import Settings, get_settings
from kp_api.domain.enums import UserRole
from kp_api.domain.models import User, Workspace, WorkspaceMember

router = APIRouter(prefix="/v1/auth", tags=["auth"])


class GoogleLoginRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id_token: str = Field(min_length=1)


class RefreshRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    refresh_token: str = Field(min_length=1)


class LogoutRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    refresh_token: str = Field(min_length=1)


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "Bearer"  # noqa: S105 (auth scheme literal, not a secret)
    access_expires_at: str
    refresh_expires_at: str


def _to_response(pair: TokenPair) -> TokenResponse:
    return TokenResponse(
        access_token=pair.access_token,
        refresh_token=pair.refresh_token,
        access_expires_at=pair.access_expires_at.isoformat(),
        refresh_expires_at=pair.refresh_expires_at.isoformat(),
    )


def get_verifier(settings: Annotated[Settings, Depends(get_settings)]) -> IdTokenVerifier:
    return GoogleIdTokenVerifier(settings)


async def _ensure_user(session: AsyncSession, settings: Settings, email: str, name: str) -> User:
    user = await session.scalar(select(User).where(User.email == email))
    if user is None:
        # First sign-in for this email — create the user and add it to the
        # singleton workspace (created on demand if this is the very first
        # login of the deployment).
        workspace = await session.scalar(select(Workspace).limit(1))
        if workspace is None:
            workspace = Workspace(name="Kulturní Přehled")
            session.add(workspace)
            await session.flush()
        is_owner = email == next(iter(settings.allowed_emails_set), None)
        user = User(
            email=email,
            name=name,
            role=UserRole.OWNER if is_owner else UserRole.MEMBER,
        )
        session.add(user)
        await session.flush()
        session.add(WorkspaceMember(workspace_id=workspace.id, user_id=user.id, role=user.role))
        await session.flush()
    elif user.name != name:
        user.name = name
        await session.flush()
    return user


@router.post(
    "/google",
    response_model=TokenResponse,
    status_code=status.HTTP_200_OK,
)
async def google_login(
    body: GoogleLoginRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
    settings: Annotated[Settings, Depends(get_settings)],
    verifier: Annotated[IdTokenVerifier, Depends(get_verifier)],
) -> TokenResponse:
    try:
        identity = verifier.verify(body.id_token)
    except OAuthError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, str(exc)) from exc
    user = await _ensure_user(session, settings, identity.email, identity.name)
    pair = await issue_tokens_for_user(session, user, settings)
    await session.commit()
    return _to_response(pair)


@router.post(
    "/refresh",
    response_model=TokenResponse,
    status_code=status.HTTP_200_OK,
)
async def refresh(
    body: RefreshRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> TokenResponse:
    try:
        pair = await rotate_refresh(session, body.refresh_token, settings)
    except AuthError as exc:
        await session.commit()  # persist any revocations we triggered
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, str(exc)) from exc
    await session.commit()
    return _to_response(pair)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(
    body: LogoutRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> None:
    try:
        await revoke_family(session, body.refresh_token, settings)
    except AuthError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, str(exc)) from exc
    await session.commit()
