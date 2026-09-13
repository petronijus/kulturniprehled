"""Enumerations used in the domain model and at the API boundary."""

from __future__ import annotations

from enum import StrEnum


class EventCategory(StrEnum):
    CONCERT = "concert"
    THEATRE = "theatre"
    CINEMA = "cinema"
    OTHER = "other"


class EventStatus(StrEnum):
    PLANNED = "planned"
    ATTENDED = "attended"
    CANCELLED = "cancelled"
    MISSED = "missed"


class EventSource(StrEnum):
    MANUAL = "manual"
    SKILL = "skill"
    RECOMMENDATION = "recommendation"


class UserRole(StrEnum):
    OWNER = "owner"
    MEMBER = "member"


class ChangeOp(StrEnum):
    UPSERT = "upsert"
    DELETE = "delete"


class CostKind(StrEnum):
    TICKET = "ticket"
    TRANSPORT = "transport"
    FOOD = "food"
    OTHER = "other"


class CostSplit(StrEnum):
    SHARED = "shared"
    INDIVIDUAL = "individual"


class WatchlistKind(StrEnum):
    # Czech category values — stored verbatim; mobile UI presents the same
    # token capitalised. Strict set: no "other" bucket by design.
    FILM = "film"
    DIVADLO = "divadlo"
    KONCERT = "koncert"


class FeedbackRating(StrEnum):
    UP = "up"
    DOWN = "down"


class SeasonStatus(StrEnum):
    ACTIVE = "active"
    ARCHIVED = "archived"


class SeasonLane(StrEnum):
    # Values match the LANE_CATEGORY keys in api/v1/digest.py — the season
    # pool and the digest pipeline speak the same lane vocabulary.
    KLASIKA = "klasika"
    ELEKTRONIKA = "elektronika"
    DIVADLO = "divadlo"
    FILM = "film"


class PlanStatus(StrEnum):
    UNDECIDED = "undecided"
    SELECTED = "selected"
    REJECTED = "rejected"


class SeatWatchState(StrEnum):
    """Where a seat watch is in its life.

    `found` is terminal on purpose: the point of a watch is one notification
    with seats in it, not a stream. Petr either takes them or starts a new
    watch — an alert he has already read must never fire again at 3am.
    """

    ACTIVE = "active"
    FOUND = "found"
    STOPPED = "stopped"
    EXPIRED = "expired"
