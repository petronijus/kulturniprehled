"""PAT authorization scopes.

A Personal Access Token is either **unrestricted** (its `scopes` column is
NULL — it acts as the full user, like the desktop skill token) or **scoped**
to an explicit set of capability strings. A scoped token is default-denied:
it may only reach endpoints that declare one of its scopes via
`require_scope`; every general endpoint rejects it outright.

Scopes are deliberately coarse and purpose-built for the headless clients we
run, not a generic RBAC surface — add a constant here when a new automation
needs a narrow door.
"""

from __future__ import annotations

# Read the precomputed weekly-digest context (event aggregates, balance
# signal, feedback sentiment, booked dates). Held by the weekly culture
# routine running in the cloud — read-only, so a leak cannot mutate data.
SCOPE_DIGEST_READ = "digest:read"

# Generate HMAC-signed 👍/👎 feedback links. The signing happens server-side
# so the routine never sees `API_JWT_SECRET`.
SCOPE_FEEDBACK_SIGN = "feedback:sign"

# Send the rendered weekly digest email. The cloud Gmail connector can only
# create drafts, so the routine hands the finished HTML to the backend, which
# relays it over SMTP to the single configured recipient. A leak can only
# email that fixed address — never an arbitrary one.
SCOPE_DIGEST_SEND = "digest:send"

# Read the events list (GET /v1/events). Held by the weekly routine so its
# history dedup (same work attended this year = hard veto) can see past
# events; read-only, mutations stay unrestricted-only.
SCOPE_EVENTS_READ = "events:read"

# Read the season-planner surface: pool, scenarios, plan summary, novelties.
# Held by the weekly novelty routine in the cloud.
SCOPE_SEASON_READ = "season:read"

# Write the season-planner surface: bulk pool/scenario upserts, plan-state
# mutations, novelty-cursor acks. The weekly routine needs it to keep the
# pool topped up; a leak cannot touch events, tickets or costs.
SCOPE_SEASON_WRITE = "season:write"

ALL_SCOPES = frozenset(
    {
        SCOPE_DIGEST_READ,
        SCOPE_FEEDBACK_SIGN,
        SCOPE_DIGEST_SEND,
        SCOPE_EVENTS_READ,
        SCOPE_SEASON_READ,
        SCOPE_SEASON_WRITE,
    }
)


def parse_scopes(raw: str | None) -> frozenset[str] | None:
    """Turn the stored space-separated scope string into a set.

    Returns None for an unrestricted token (NULL column) so callers can treat
    `None` as "no restriction" distinctly from an empty set ("restricted to
    nothing")."""

    if raw is None:
        return None
    return frozenset(raw.split())


def format_scopes(scopes: list[str] | None) -> str | None:
    """Inverse of `parse_scopes` for storage."""

    if scopes is None:
        return None
    return " ".join(scopes)
