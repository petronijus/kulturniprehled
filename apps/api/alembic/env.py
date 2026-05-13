"""Alembic migration environment.

Alembic itself is synchronous. The application uses async SQLAlchemy, so we
convert the async URL to a sync one (`postgresql+asyncpg://` →
`postgresql+psycopg://` if available, else `postgresql+psycopg2`) when
running migrations. This sidesteps the "coroutine never awaited" problem
that hits us when migrations are kicked off from inside a running asyncio
loop (e.g. pytest-asyncio fixtures).
"""

from __future__ import annotations

from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from kp_api.config import get_settings
from kp_api.domain.models import Base

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def _sync_url() -> str:
    async_url = get_settings().database_url
    return async_url.replace("+asyncpg", "+psycopg", 1)


config.set_main_option("sqlalchemy.url", _sync_url())


def run_migrations_offline() -> None:
    context.configure(
        url=config.get_main_option("sqlalchemy.url"),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
