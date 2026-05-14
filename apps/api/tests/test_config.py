from kp_api.config import Settings


def test_google_oauth_audiences_single() -> None:
    s = Settings(google_oauth_client_id="web-id.apps.googleusercontent.com")
    assert s.google_oauth_audiences == ["web-id.apps.googleusercontent.com"]


def test_google_oauth_audiences_comma_separated() -> None:
    s = Settings(
        google_oauth_client_id="web-id.apps.googleusercontent.com,ios-id.apps.googleusercontent.com"
    )
    assert s.google_oauth_audiences == [
        "web-id.apps.googleusercontent.com",
        "ios-id.apps.googleusercontent.com",
    ]


def test_google_oauth_audiences_empty() -> None:
    s = Settings(google_oauth_client_id="")
    assert s.google_oauth_audiences == []


def test_google_oauth_audiences_strips_whitespace() -> None:
    s = Settings(google_oauth_client_id="  a  ,  b  ,, c  ")
    assert s.google_oauth_audiences == ["a", "b", "c"]
