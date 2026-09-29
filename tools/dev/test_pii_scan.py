#!/usr/bin/env python3
"""Tests for tools/dev/pii-scan.py against throwaway git repos.

Stdlib only, like the other script tests (`python3 tools/dev/test_pii_scan.py`).
The patterns here are made up; the real list never enters this repo.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCAN = Path(__file__).resolve().with_name("pii-scan.py")


class PiiScanTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name) / "repo"
        self.repo.mkdir()
        self.patterns = Path(self._tmp.name) / "patterns.txt"
        self.patterns.write_text(
            "# comment lines and blank lines are ignored\n"
            "\n"
            "secret-host\\.lan\n"
            "10\\.9\\.[0-9]+\\.[0-9]+\n",
            encoding="utf-8",
        )
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.write("notes.md", "first\nsecond\nthird\nfourth\nfifth\n")
        self.git("add", "notes.md")
        self.git("commit", "-q", "-m", "init")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.repo, check=True)

    def write(self, name: str, text: str) -> None:
        (self.repo / name).write_text(text, encoding="utf-8")

    def scan(self, patterns: Path | None = None) -> subprocess.CompletedProcess[str]:
        env = {**os.environ, "KP_PII_PATTERNS": str(patterns or self.patterns)}
        return subprocess.run(
            [sys.executable, str(SCAN)], cwd=self.repo, env=env, capture_output=True, text=True
        )

    def test_clean_staged_change_passes(self) -> None:
        self.write("notes.md", "first\nsecond\nthird\nfourth\nfifth\nsixth\n")
        self.git("add", "notes.md")
        self.assertEqual(self.scan().returncode, 0)

    def test_added_line_with_private_data_fails_with_its_location(self) -> None:
        self.write("notes.md", "first\nsecond\nthird\nfourth\nfifth\nssh to secret-host.lan\n")
        self.git("add", "notes.md")
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn("notes.md:6: secret-host.lan", result.stderr)

    def test_line_numbers_follow_each_hunk(self) -> None:
        self.write("notes.md", "first\n10.9.1.2\nthird\nfourth\nfifth\n10.9.3.4\n")
        self.git("add", "notes.md")
        result = self.scan()
        self.assertIn("notes.md:2: 10.9.1.2", result.stderr)
        self.assertIn("notes.md:6: 10.9.3.4", result.stderr)

    def test_new_file_is_scanned(self) -> None:
        self.write("new.txt", "host: secret-host.lan\n")
        self.git("add", "new.txt")
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn("new.txt:1:", result.stderr)

    def test_file_with_a_non_ascii_path_is_scanned(self) -> None:
        self.write("poznámky.md", "secret-host.lan\n")
        self.git("add", "poznámky.md")
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn("poznámky.md:1:", result.stderr)

    def test_removing_private_data_passes(self) -> None:
        self.write("notes.md", "secret-host.lan\n")
        self.git("commit", "-q", "-am", "leak")
        self.write("notes.md", "placeholder.example.com\n")
        self.git("add", "notes.md")
        self.assertEqual(self.scan().returncode, 0)

    def test_unstaged_changes_are_not_scanned(self) -> None:
        self.write("notes.md", "secret-host.lan\n")
        self.assertEqual(self.scan().returncode, 0)

    def test_missing_pattern_file_skips_loudly(self) -> None:
        self.write("notes.md", "secret-host.lan\n")
        self.git("add", "notes.md")
        result = self.scan(Path(self._tmp.name) / "absent.txt")
        self.assertEqual(result.returncode, 0)
        self.assertIn("SKIPPED", result.stderr)


if __name__ == "__main__":
    unittest.main()
