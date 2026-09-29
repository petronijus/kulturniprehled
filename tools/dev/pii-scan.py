#!/usr/bin/env python3
"""Pre-commit PII scan: the repo is public, so private infrastructure and
personal data must never enter it.

Checks the lines a commit adds (the staged diff) against the repo-hygiene
skill's private regex list. The list stays outside the repo; nothing here
names what it contains. Lines already in the repo are the repo-hygiene
audit's business, not this hook's.

    tools/dev/pii-scan.py            scan the staged diff
    KP_PII_PATTERNS=<file>           use another pattern file

Exit 1 on a match, 0 when clean. A missing pattern file is reported and
skipped (exit 0), so a machine without the skill can still commit.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_PATTERNS = Path.home() / ".claude/skills/repo-hygiene/patterns.txt"
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def load_patterns(path: Path) -> list[re.Pattern[str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    return [re.compile(line) for line in lines if line.strip() and not line.startswith("#")]


def added_lines(diff: str) -> list[tuple[str, int, str]]:
    """(path, line number, text) for every line the diff adds."""
    found: list[tuple[str, int, str]] = []
    path, number = "", 0
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else ""
        elif line.startswith("@@"):
            match = HUNK.match(line)
            number = int(match.group(1)) if match else 0
        elif line.startswith("+") and path:
            found.append((path, number, line[1:]))
            number += 1
        elif line.startswith(" "):  # context, only with -U > 0
            number += 1
    return found


def scan(diff: str, patterns: list[re.Pattern[str]]) -> list[tuple[str, int, str]]:
    hits: list[tuple[str, int, str]] = []
    for path, number, text in added_lines(diff):
        for pattern in patterns:
            match = pattern.search(text)
            if match:
                hits.append((path, number, match.group(0)))
    return hits


def main() -> int:
    patterns_file = Path(os.environ.get("KP_PII_PATTERNS") or DEFAULT_PATTERNS)
    if not patterns_file.is_file():
        print(
            f"pii-scan: {patterns_file} not found; PII scan SKIPPED "
            "(set KP_PII_PATTERNS or sync the repo-hygiene skill)",
            file=sys.stderr,
        )
        return 0
    diff = subprocess.run(
        [
            "git",
            "-c",
            "core.quotePath=false",
            "diff",
            "--cached",
            "--no-color",
            "--no-ext-diff",
            "-U0",
        ],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    ).stdout
    hits = scan(diff, load_patterns(patterns_file))
    if not hits:
        return 0
    print("pii-scan: this repo is public; the staged changes add private data:", file=sys.stderr)
    for path, number, match in hits:
        print(f"  {path}:{number}: {match}", file=sys.stderr)
    print(
        "Replace it with a placeholder (192.0.2.x, example.com, …) and keep the real value "
        "in the private overlay (private/).",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
