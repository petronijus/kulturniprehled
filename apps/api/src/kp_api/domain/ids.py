"""UUID generation helpers.

We use UUIDv7 for all primary keys so the IDs sort chronologically — better
index locality on Postgres B-trees than random v4 IDs, and trivially debuggable
("which one came first?"). The native Python stdlib does not ship v7 in 3.12,
so we delegate to `uuid_utils`.
"""

from __future__ import annotations

from uuid import UUID

import uuid_utils


def uuid7() -> UUID:
    return UUID(str(uuid_utils.uuid7()))
