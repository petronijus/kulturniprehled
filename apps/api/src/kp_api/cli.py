"""Administrative CLI.

Exposes one-shot commands that don't fit the HTTP surface yet — chiefly
minting a personal access token for a headless client (e.g. the Claude Code
skill running on the desktop).

Typical use during deployment:

    docker compose exec api python -m kp_api.cli mint-pat \\
        --email petr@example.com \\
        --name 'desktop-skill'

The JWT is printed to stdout once. Capture it directly into 1Password:

    PAT=$(docker compose exec api python -m kp_api.cli mint-pat \\
        --email ... --name skill --quiet)
    op item edit 'Kulturni Prehled API Token' "credential=$PAT"
"""

from __future__ import annotations

import argparse
import asyncio
import sys

from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker

from kp_api.adapters.auth import mint_pat
from kp_api.adapters.db import get_engine
from kp_api.config import get_settings
from kp_api.domain.enums import UserRole
from kp_api.domain.models import User, Workspace, WorkspaceMember


async def _cmd_mint_pat(email: str, name: str, quiet: bool) -> int:
    settings = get_settings()
    factory = async_sessionmaker(bind=get_engine(), expire_on_commit=False)
    async with factory() as session:
        user = await session.scalar(select(User).where(User.email == email.lower()))
        if user is None:
            print(
                f"error: no user with email '{email}'. Have them sign in once "
                "or seed manually first.",
                file=sys.stderr,
            )
            return 2
        token = await mint_pat(session, user, name=name, settings=settings)
        await session.commit()

    if not quiet:
        print(
            "Personal access token (copy now — it is not stored on the server "
            "in plaintext):",
            file=sys.stderr,
        )
    sys.stdout.write(token + "\n")
    return 0


async def _cmd_seed_user(email: str, name: str | None) -> int:
    """Create a user + workspace row by hand. Useful before the first
    interactive Google login is set up (e.g. for the skill in dev)."""

    settings = get_settings()
    factory = async_sessionmaker(bind=get_engine(), expire_on_commit=False)
    async with factory() as session:
        existing = await session.scalar(select(User).where(User.email == email.lower()))
        if existing is not None:
            print(f"user already exists: {existing.id}", file=sys.stderr)
            return 0
        workspace = await session.scalar(select(Workspace).limit(1))
        if workspace is None:
            workspace = Workspace(name="Kulturní Přehled")
            session.add(workspace)
            await session.flush()
        is_owner = email.lower() in settings.allowed_emails_set
        user = User(
            email=email.lower(),
            name=name or email,
            role=UserRole.OWNER if is_owner else UserRole.MEMBER,
        )
        session.add(user)
        await session.flush()
        session.add(
            WorkspaceMember(
                workspace_id=workspace.id, user_id=user.id, role=user.role
            )
        )
        await session.commit()
        print(f"created user {user.id} in workspace {workspace.id}", file=sys.stderr)
        return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="kp_api.cli", description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    mp = sub.add_parser("mint-pat", help="Mint a long-lived PAT for a user")
    mp.add_argument("--email", required=True)
    mp.add_argument("--name", required=True, help="human label for the token")
    mp.add_argument(
        "--quiet", action="store_true", help="suppress hints, print only the token"
    )

    seed = sub.add_parser("seed-user", help="Create a user row without OAuth")
    seed.add_argument("--email", required=True)
    seed.add_argument("--name", default=None)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.cmd == "mint-pat":
        return asyncio.run(_cmd_mint_pat(args.email, args.name, args.quiet))
    if args.cmd == "seed-user":
        return asyncio.run(_cmd_seed_user(args.email, args.name))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
