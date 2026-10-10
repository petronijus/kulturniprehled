#!/usr/bin/env python3
"""Tests for session_settings.py: the sandbox is on and cannot be left, and
the deny rules reach both the file tools and the shell.

Stdlib only and runnable on its own (`python3 test_session_settings.py`), the
same deal as test_seat_watch.py. The last test builds the settings from the
real lists next to it.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile

HERE = pathlib.Path(__file__).parent
spec = importlib.util.spec_from_file_location("session_settings", HERE / "session_settings.py")
assert spec is not None and spec.loader is not None
ss = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ss)

passed = 0


def ok(name: str) -> None:
    global passed
    passed += 1
    print(f"ok   - {name}")


def test_rules_fill_placeholders_and_skip_comments() -> None:
    with tempfile.TemporaryDirectory() as d:
        f = pathlib.Path(d, "r.txt")
        f.write_text("# comment\n\nRead(/{HOME}/.ssh/**)\n  Edit(/{REPO}/**)  \n")
        got = ss.rules(f, "/home/u", "/home/u/kp")
    assert got == ["Read(//home/u/.ssh/**)", "Edit(//home/u/kp/**)"], got
    ok("rules fill {HOME}/{REPO} and skip comments")


def test_deny_read_paths() -> None:
    got = ss.deny_read_paths(
        [
            "Read(//home/u/.ssh/**)",
            "Read(//home/u/.claude.json)",
            "WebFetch",
            "Edit(//x/**)",
            "Bash(rm:*)",
        ]
    )
    assert got == ["/home/u/.ssh", "/home/u/.claude.json"], got
    ok("Read deny rules become sandbox denyRead paths; others are ignored")


def test_sandbox_cannot_be_left() -> None:
    s = ss.build(["Bash"], ["Read(//h/.ssh/**)"], ["kulturniprehled.example.com"])["sandbox"]
    assert s["enabled"] is True
    assert s["failIfUnavailable"] is True, "a missing bwrap must stop the run, not unsandbox it"
    assert s["allowUnsandboxedCommands"] is False, "dangerouslyDisableSandbox must be ignored"
    assert s["autoAllowBashIfSandboxed"] is True
    assert s["network"]["allowedDomains"] == ["kulturniprehled.example.com"]
    assert s["filesystem"]["allowWrite"] == ["/tmp"]
    assert s["filesystem"]["denyRead"] == ["/h/.ssh"]
    assert "excludedCommands" not in s, "nothing may run outside the sandbox"
    ok("sandbox on, fail-closed, no unsandboxed retry, no excluded commands")


def test_bad_domain_rejected() -> None:
    for bad in ("https://x.cz", "x.cz/path", "", "a b"):
        try:
            ss.build([], [], [bad])
        except ValueError:
            continue
        raise AssertionError(f"accepted {bad!r}")
    ok("URLs and blanks are not domains")


def test_url_host() -> None:
    assert ss.url_host("https://kp.example.com/v1/x?y=1") == "kp.example.com"
    assert ss.url_host("http://kp.example.com:8080") == "kp.example.com"
    for bad in ("kp.example.com", "ftp://kp.example.com", "https://"):
        try:
            ss.url_host(bad)
        except ValueError:
            continue
        raise AssertionError(f"accepted {bad!r}")
    ok("--url hosts come from http(s) URLs only")


def test_real_lists() -> None:
    tmp = tempfile.TemporaryDirectory()
    local = pathlib.Path(tmp.name, "sandbox-domains.local")
    local.write_text("# box-local\ntickets.example.com\nwww.fok.cz\n")
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = ss.main(
            [
                "--allowed",
                str(HERE / "allowed-tools-weekly.txt"),
                "--denied",
                str(HERE / "denied-tools.txt"),
                "--domains",
                str(HERE / "sandbox-domains.txt"),
                "--domains",
                str(local),
                "--url",
                "https://kulturniprehled.example.com",
                "--home",
                "/home/u",
                "--repo",
                "/home/u/Documents/Dev/kulturniprehled",
            ]
        )
    assert rc == 0
    s = json.loads(out.getvalue())
    allow, deny = s["permissions"]["allow"], s["permissions"]["deny"]
    assert "Bash" in allow, "the runs need Bash whole; the sandbox bounds it"
    assert "Write" not in allow and "Edit" not in allow, "file writes must stay scoped"
    assert "Edit(//home/u/Documents/Dev/kulturniprehled/**)" in allow
    assert not any("{" in r for r in allow + deny), "unfilled placeholder"
    deny_read = s["sandbox"]["filesystem"]["denyRead"]
    for secret in ("/home/u/.ssh", "/home/u/.config/gh", "/home/u/Documents/Dev/ai-config"):
        assert secret in deny_read, secret
    assert "kulturniprehled.example.com" in s["sandbox"]["network"]["allowedDomains"]
    domains = s["sandbox"]["network"]["allowedDomains"]
    assert "www.fok.cz" in domains and "tickets.example.com" in domains
    assert domains.count("www.fok.cz") == 1, "duplicates across files are merged"
    tmp.cleanup()
    ok("the real lists build a sandboxed, scoped session")


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print(f"{passed} passed")
