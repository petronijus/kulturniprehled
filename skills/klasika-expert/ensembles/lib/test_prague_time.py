"""Tests for prague_time.py. Run: python3 test_prague_time.py"""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from prague_time import prague_parts, stamp, wall_clock

HELPER = Path(__file__).resolve().parent / "prague_time.py"


class WallClockTest(unittest.TestCase):
    def test_winter_date_gets_winter_offset(self) -> None:
        # The 2026-10-31 opera: 19:00 on the ticket, a week after DST ended.
        self.assertEqual(wall_clock("2026-10-31 19:00"), "2026-10-31T19:00:00+01:00")

    def test_summer_date_gets_summer_offset(self) -> None:
        self.assertEqual(wall_clock("2026-06-12T20:00"), "2026-06-12T20:00:00+02:00")

    def test_other_zone(self) -> None:
        self.assertEqual(
            wall_clock("2026-11-20 19:30", "Europe/London"),
            "2026-11-20T19:30:00+00:00",
        )

    def test_refuses_a_hand_written_offset(self) -> None:
        with self.assertRaises(ValueError):
            wall_clock("2026-10-31T19:00:00+02:00")

    def test_refuses_a_time_inside_the_spring_gap(self) -> None:
        with self.assertRaises(ValueError):
            wall_clock("2027-03-28 02:30")

    def test_refuses_an_unknown_zone(self) -> None:
        with self.assertRaises(ValueError):
            wall_clock("2026-10-31 19:00", "Europe/Atlantis")

    def test_command_line(self) -> None:
        done = subprocess.run(
            [sys.executable, str(HELPER), "wall-clock", "2026-10-31 19:00"],
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(done.stdout.strip(), "2026-10-31T19:00:00+01:00")

    def test_command_line_failure_is_loud(self) -> None:
        done = subprocess.run(
            [sys.executable, str(HELPER), "wall-clock", "2027-03-28 02:30"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(done.returncode, 1)
        self.assertIn("does not exist", done.stderr)


class ExistingHelpersTest(unittest.TestCase):
    def test_prague_parts_resolves_dst(self) -> None:
        self.assertEqual(prague_parts(2026, 11, 9, 19, 30), "2026-11-09T19:30:00+01:00")

    def test_stamp_throws_away_a_lying_z(self) -> None:
        self.assertEqual(
            stamp("2026-09-26T20:15:00Z", trust_offset=False),
            "2026-09-26T20:15:00+02:00",
        )


if __name__ == "__main__":
    unittest.main()
