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
