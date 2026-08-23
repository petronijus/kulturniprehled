#!/usr/bin/env python3
"""Regression tests for kp_validate.py (stdlib-only, like the module itself)."""

from __future__ import annotations

import unittest

from kp_validate import as_prague, timed_conflict


class TimedConflictTz(unittest.TestCase):
    """Naive calendar stamps vs tz-aware event stamps must compare cleanly.

    The 2026-08-23 season run crashed with `TypeError: can't compare
    offset-naive and offset-aware datetimes` — the season calendar API
    emits naive local stamps while scrapers emit `+02:00` offsets.
    """

    BLOCKED = {
        "blocked_days": [],
        "conflicts": [
            {
                "start_iso": "2026-11-02T17:30:00",
                "end_iso": "2026-11-02T21:00:00",
                "title": "UX Monday",
            }
        ],
    }

    def test_aware_event_vs_naive_conflict(self) -> None:
        conflict = timed_conflict(
            "2026-11-02", "2026-11-02T20:00:00+01:00", self.BLOCKED
        )
        self.assertEqual(conflict, "UX Monday")

    def test_naive_event_vs_naive_conflict(self) -> None:
        conflict = timed_conflict("2026-11-02", "2026-11-02T20:00:00", self.BLOCKED)
        self.assertEqual(conflict, "UX Monday")

    def test_event_clear_of_conflict(self) -> None:
        conflict = timed_conflict(
            "2026-11-03", "2026-11-03T20:00:00+01:00", self.BLOCKED
        )
        self.assertIsNone(conflict)

    def test_utc_z_suffix_event(self) -> None:
        # 19:00Z == 20:00 Prague in November — inside the conflict window.
        conflict = timed_conflict("2026-11-02", "2026-11-02T19:00:00Z", self.BLOCKED)
        self.assertEqual(conflict, "UX Monday")

    def test_as_prague_naive_is_wall_time(self) -> None:
        moment = as_prague("2026-11-02T20:00:00")
        self.assertEqual(moment.utcoffset().total_seconds(), 3600)


if __name__ == "__main__":
    unittest.main()
