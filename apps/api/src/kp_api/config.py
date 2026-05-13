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
    postgres_password: str = "changeme"

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
    minio_secret_key: str = "changeme-changeme"
    minio_bucket_tickets: str = "tickets"
    minio_region: str = "eu-central-1"
    minio_use_ssl: bool = False
    minio_presigned_url_ttl_seconds: int = 900

    # API
    api_host: str = "0.0.0.0"  # noqa: S104  (binding inside container)
    api_port: int = 8000
    api_jwt_secret: str = "replace-me"
    api_jwt_access_ttl_seconds: int = 900
    api_jwt_refresh_ttl_seconds: int = 2_592_000

    # Google OAuth
    google_oauth_client_id: str = ""
    google_oauth_client_secret: str = ""
    google_calendar_id: str = ""

    allowed_emails: str = ""

    # Anthropic
    anthropic_api_key: str = ""
    anthropic_model: str = "claude-sonnet-4-6"

    # Error reporting (Sentry / GlitchTip). When empty the SDK is not
    # initialised at all — dev runs stay silent.
    sentry_dsn: str = ""
    sentry_environment: str = "dev"
    sentry_traces_sample_rate: float = 0.0

    log_level: str = "INFO"

    # Derived
    @property
    def database_url(self) -> str:
        return (
            f"postgresql+asyncpg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    @property
    def allowed_emails_set(self) -> frozenset[str]:
        return frozenset(
            e.strip().lower() for e in self.allowed_emails.split(",") if e.strip()
        )

    enabled_features: list[str] = Field(default_factory=list)


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
