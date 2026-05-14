"""Google OAuth ID-token verification.

Mobile clients perform the OAuth Authorization-Code-with-PKCE dance with
Google directly and post the resulting ID token to `/v1/auth/google`. The
backend re-verifies the ID token against Google's JWKS so it never trusts
client-side validation, then enforces the workspace email whitelist.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from google.auth.transport import requests as google_requests
from google.oauth2 import id_token as google_id_token

from kp_api.config import Settings

_GOOGLE_ISSUERS = frozenset({"accounts.google.com", "https://accounts.google.com"})


class OAuthError(Exception):
    """Raised when an ID token fails verification or is not allowed."""


@dataclass(frozen=True)
class GoogleIdentity:
    sub: str
    email: str
    name: str


class IdTokenVerifier(Protocol):
    def verify(self, id_token: str) -> GoogleIdentity: ...


class GoogleIdTokenVerifier:
    def __init__(self, settings: Settings, request: object | None = None) -> None:
        self._settings = settings
        self._request = request or google_requests.Request()

    def verify(self, id_token: str) -> GoogleIdentity:
        try:
            audiences = self._settings.google_oauth_audiences
            claims = google_id_token.verify_oauth2_token(  # type: ignore[no-untyped-call]
                id_token,
                self._request,
                audience=audiences or None,
            )
        except ValueError as exc:
            raise OAuthError(f"invalid id token: {exc}") from exc

        if claims.get("iss") not in _GOOGLE_ISSUERS:
            raise OAuthError("unexpected issuer")
        email = str(claims.get("email", "")).lower()
        if not email:
            raise OAuthError("id token missing email")
        if not claims.get("email_verified"):
            raise OAuthError("email not verified")
        if email not in self._settings.allowed_emails_set:
            raise OAuthError("email not allowed")
        return GoogleIdentity(
            sub=str(claims.get("sub", "")),
            email=email,
            name=str(claims.get("name") or email),
        )
