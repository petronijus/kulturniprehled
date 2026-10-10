#!/usr/bin/env python3
"""Build the --settings file of a headless kulturni-prehled session.

The runs start `claude -p --restricted --settings <this file>`: in restricted
mode the box's user, project and local settings are not loaded, so this file
is the whole boundary next to the CLI flags. It holds

  * permissions.allow / permissions.deny — from allowed-tools-weekly.txt and
    denied-tools.txt ({HOME} and {REPO} filled in);
  * sandbox — Bash runs inside bubblewrap: no write outside the checkout and
    /tmp, no read of the denied places, network only to the allowed hosts,
    and no way back out (allowUnsandboxedCommands false, failIfUnavailable
    true).

The allowed hosts are the public ones in sandbox-domains.txt, the host of
every --url (the runner passes $KP_API_BASE), and any further --domains
file — on the box, ~/.config/kulturni-prehled/sandbox-domains.local for
private hosts, which stay out of this public repo.

The runs need Bash whole (multi-line python heredocs, jq pipelines, $(...))
and they read untrusted web pages, so the sandbox, not an allow-list of
commands, is what keeps them away from the box's other credentials (the gh
token, SSH keys, other runners' tokens) and from writing anywhere that runs
later (ai-config, ~/.bashrc, systemd units).

Every `Read(//abs/path/**)` deny rule is also put into
sandbox.filesystem.denyRead, so the file tools and the shell share one list.

    session_settings.py --allowed F --denied F --domains F [--domains F]...
                        [--url URL]... --home H --repo R
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

READ_RULE = re.compile(r"^Read\((//[^)]*)\)$")


def rules(path: Path, home: str, repo: str) -> list[str]:
    """One rule per non-comment line, with {HOME} and {REPO} filled in."""
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.append(line.replace("{HOME}", home).replace("{REPO}", repo))
    return out


def deny_read_paths(deny: list[str]) -> list[str]:
    """Sandbox paths for the Read deny rules: `Read(//a/b/**)` -> `/a/b`."""
    paths = []
    for rule in deny:
        m = READ_RULE.match(rule)
        if not m:
            continue
        path = m.group(1)[1:]  # "//abs" is the absolute form of a permission rule
        if path.endswith("/**"):
            path = path[: -len("/**")]
        paths.append(path)
    return paths


def url_host(url: str) -> str:
    """The host of an http(s) URL: `https://api.example.com/v1` -> `api.example.com`."""
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ValueError(f"not an http(s) URL: {url!r}")
    return parts.hostname


def build(allow: list[str], deny: list[str], domains: list[str]) -> dict:
    for d in domains:
        if "/" in d or " " in d or not d:
            raise ValueError(f"not a domain: {d!r}")
    return {
        "permissions": {"allow": allow, "deny": deny},
        "sandbox": {
            "enabled": True,
            "failIfUnavailable": True,
            "autoAllowBashIfSandboxed": True,
            "allowUnsandboxedCommands": False,
            "network": {"allowedDomains": domains},
            "filesystem": {
                # the checkout is the working directory (writable already);
                # /tmp holds the runs' work dirs (/tmp/kp-digest-CW<n>, …)
                "allowWrite": ["/tmp"],
                "denyRead": deny_read_paths(deny),
            },
        },
    }


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--allowed", required=True, type=Path)
    p.add_argument("--denied", required=True, type=Path)
    p.add_argument("--domains", required=True, type=Path, action="append")
    p.add_argument("--url", default=[], action="append", help="allow this URL's host")
    p.add_argument("--home", required=True)
    p.add_argument("--repo", required=True)
    a = p.parse_args(argv)
    for name, value in (("--home", a.home), ("--repo", a.repo)):
        if not value.startswith("/"):
            p.error(f"{name} must be absolute")
    domains: list[str] = []
    for f in a.domains:
        domains += rules(f, a.home, a.repo)
    domains += [url_host(u) for u in a.url]
    settings = build(
        rules(a.allowed, a.home, a.repo),
        rules(a.denied, a.home, a.repo),
        list(dict.fromkeys(domains)),
    )
    json.dump(settings, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
