"""The real Google ID-token verifier (conftest fakes it for the API tests).

google-auth's network and signature check is replaced by a stub that
records what it was asked; what matters here is what the verifier demands
before and after it.
"""

from typing import Any

import pytest

from kp_api.adapters import oauth
from kp_api.adapters.oauth import GoogleIdTokenVerifier, OAuthError
from kp_api.config import Settings

CLIENT = "web-id.apps.googleusercontent.com"


@pytest.fixture
def google(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """Stubs Google's verification; returns the record of the last call and
    the claims it will answer with."""
    state: dict[str, Any] = {
        "claims": {
            "iss": "https://accounts.google.com",
            "sub": "1234",
            "email": "Someone@Example.com",
            "email_verified": True,
            "name": "Someone",
        },
        "calls": [],
    }

    def fake_verify(token: str, request: object, audience: Any = None) -> dict[str, Any]:
        state["calls"].append({"token": token, "audience": audience})
        return dict(state["claims"])

    monkeypatch.setattr(oauth.google_id_token, "verify_oauth2_token", fake_verify)
    return state


def verifier(
    client_id: str = CLIENT, allowed: str = "someone@example.com"
) -> GoogleIdTokenVerifier:
    settings = Settings(google_oauth_client_id=client_id, allowed_emails=allowed)
    return GoogleIdTokenVerifier(settings, request=object())


def test_an_allowed_account_signs_in_and_the_audience_is_checked(google: dict[str, Any]) -> None:
    identity = verifier().verify("token")
    assert identity.email == "someone@example.com"
    assert identity.sub == "1234"
    assert google["calls"] == [{"token": "token", "audience": [CLIENT]}]


def test_without_a_client_id_every_token_is_refused_unchecked(google: dict[str, Any]) -> None:
    with pytest.raises(OAuthError, match="not configured"):
        verifier(client_id="").verify("token")
    # Never handed to google-auth with audience=None, which skips `aud`.
    assert google["calls"] == []


def test_an_account_off_the_allowlist_is_refused(google: dict[str, Any]) -> None:
    with pytest.raises(OAuthError, match="not allowed"):
        verifier(allowed="other@example.com").verify("token")


def test_an_empty_allowlist_admits_nobody(google: dict[str, Any]) -> None:
    with pytest.raises(OAuthError, match="not allowed"):
        verifier(allowed="").verify("token")


def test_an_unverified_email_is_refused(google: dict[str, Any]) -> None:
    google["claims"]["email_verified"] = False
    with pytest.raises(OAuthError, match="not verified"):
        verifier().verify("token")


def test_a_foreign_issuer_is_refused(google: dict[str, Any]) -> None:
    google["claims"]["iss"] = "https://evil.example"
    with pytest.raises(OAuthError, match="issuer"):
        verifier().verify("token")
