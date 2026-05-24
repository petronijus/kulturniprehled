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
