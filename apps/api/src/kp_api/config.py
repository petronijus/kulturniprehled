"""Runtime configuration loaded from environment variables.

Values come from the process environment; a `.env` file is loaded when present
for local development. Settings are validated on import — if a required value
is missing the process refuses to start.
"""

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # Postgres
    postgres_host: str = "localhost"
    postgres_port: int = 5432
    postgres_db: str = "kp"
    postgres_user: str = "kp"
    postgres_password: str = "changeme"  # noqa: S105 (dev default, prod overrides)

    # MinIO
    minio_endpoint: str = "localhost:9000"
    # Public endpoint baked into presigned URLs. Defaults to `minio_endpoint`
    # so dev / tests work with a single hostname. In production set this to
    # the Cloudflare-tunnel-fronted host (e.g. `tickets.kp.example.com`) so
    # mobile clients reach MinIO via the public URL; SigV4 signs the host
    # header, so the URL must already point at the host that will receive
    # the request.
    minio_public_endpoint: str | None = None
    minio_public_use_ssl: bool | None = None
    minio_access_key: str = "kp-minio"
    minio_secret_key: str = "changeme-changeme"  # noqa: S105 (dev default, prod overrides)
    minio_bucket_tickets: str = "tickets"
    # Event hero / venue photos uploaded by the ingest skill. Public
    # read so the mobile app can fetch URLs without round-tripping the
    # API for a presigned GET — covers aren't sensitive, the bucket
    # only ever sees what the skill or a logged-in user uploads.
    minio_bucket_images: str = "event-images"
    minio_region: str = "eu-central-1"
    minio_use_ssl: bool = False
    minio_presigned_url_ttl_seconds: int = 900

    # API
    api_host: str = "0.0.0.0"  # noqa: S104  (binding inside container)
    api_port: int = 8000
    api_jwt_secret: str = "replace-me"  # noqa: S105 (dev default, prod overrides)
    api_jwt_access_ttl_seconds: int = 900
    api_jwt_refresh_ttl_seconds: int = 2_592_000
    # Reuse of a just-rotated refresh token within this window is treated as
    # a benign client-side race (two isolates of one app, lost response) —
    # the request is rejected but the token family survives. Beyond it,
    # reuse is assumed hostile and burns the family.
    api_refresh_reuse_grace_seconds: int = 60

    # Google OAuth
    google_oauth_client_id: str = ""
    google_oauth_client_secret: str = ""
    google_calendar_id: str = ""

    allowed_emails: str = ""

    # Anthropic
    anthropic_api_key: str = ""
    anthropic_model: str = "claude-sonnet-4-6"

    # Discogs — Petr's vinyl collection is the klasika lane's long-term taste
    # anchor, served to the cloud digest routine via /v1/digest/context so the
    # routine needs no Discogs token of its own. Optional: empty disables it
    # and the endpoint returns `discogs: null`.
    discogs_token: str = ""
    discogs_username: str = ""

    # SMTP relay for the digest email. The cloud Gmail connector can only draft,
    # so POST /v1/digest/send relays the rendered HTML over SMTP. Provider-
    # agnostic (Gmail SMTP, a self-hosted server, a transactional service —
    # whatever the env points at). `digest_mail_to` is the ONLY recipient the
    # send endpoint will target, so a leaked digest:send token can't spam.
    # Empty `smtp_host` → the endpoint 503s (feature disabled).
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_user: str = ""
    smtp_password: str = ""
    smtp_starttls: bool = True
    digest_mail_from: str = ""
    digest_mail_to: str = ""

    # Error reporting (Sentry / GlitchTip). When empty the SDK is not
    # initialised at all — dev runs stay silent.
    sentry_dsn: str = ""
    sentry_environment: str = "dev"
    sentry_traces_sample_rate: float = 0.0

    log_level: str = "INFO"

    # Rate limiting — IP-based via slowapi. Tests turn this off so they
    # can hammer endpoints without tripping the limiter.
    rate_limit_enabled: bool = True
    rate_limit_default: str = "120/minute"
    rate_limit_auth_login: str = "10/minute"
    rate_limit_auth_refresh: str = "30/minute"

    # Derived
    @property
    def database_url(self) -> str:
        return (
            f"postgresql+asyncpg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    @property
    def allowed_emails_set(self) -> frozenset[str]:
        return frozenset(e.strip().lower() for e in self.allowed_emails.split(",") if e.strip())

    @property
    def google_oauth_audiences(self) -> list[str]:
        # Mobile platforms diverge: Android sets the ID token's `aud` to the
        # web `serverClientId`, while iOS pins it to the in-app `GIDClientID`
        # (the iOS OAuth client). The env value is a comma-separated list so
        # we accept both — and the same setting still works with a single ID.
        return [a.strip() for a in self.google_oauth_client_id.split(",") if a.strip()]

    enabled_features: list[str] = Field(default_factory=list)


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
