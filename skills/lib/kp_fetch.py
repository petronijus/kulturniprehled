#!/usr/bin/env python3
"""Every page the venue scrapers read goes through here: a persistent cache
with a cadence per kind of page, conditional requests, a per-host request
budget and a per-host cooldown that outlives the run.

Why this exists. The scrapers used to fetch everything on every run: up to
20 listing pages per orchestra plus one detail page per production, weekly,
and again for the season run and for every rehearsal. fok.cz answers that by
dropping this network's address — "stopped answering after 51 of 64 detail
pages" (2026-09-27), dark again on 2026-10-10 after two passes in five
minutes, for hours and for every device at home. Yet those pages barely
change all year: a season's programme is published once, then sits. So the
data is cached, and the servers are only asked again when a page is old:

* **cadence per kind** — an orchestra's listing and a production's detail
  page are re-checked after about four weeks, a club feed after about a week,
  the detail page of a concert the ticket watchdog follows after a few days
  (`KP_FETCH_FRESH_URLS`). Each URL's age limit is shortened by a stable
  0–25 % jitter, so a site's pages do not all fall due in the same week.
* **conditional requests** — a page that has not changed costs a 304, not a
  download (`If-None-Match` / `If-Modified-Since` from the cached response).
* **a budget per host** — at most N requests in any 24 hours, across every
  process and run, with a minimum gap between two requests. A page that does
  not fit is served from the cache, stale, and refreshed by a later run; a
  first fill of an empty cache therefore spreads over several runs.
* **a cooldown per host** — a timeout, a refused connection, 403, 429 or 5xx
  closes the host for 6 hours, doubling on every repeat up to 7 days (or the
  server's Retry-After, if longer). Nothing is sent to it meanwhile; the
  cache answers. Hammering a host that has started refusing is what turned a
  short rate limit into a ban.

Fetching shells out to `curl`, like the scrapers always did: these hosts
answer it, and a second HTTP client would be a second set of TLS and redirect
quirks to keep working. `curl` honours the proxy the sandbox sets.

Storage: $KP_FETCH_CACHE, else $XDG_CACHE_HOME/kulturni-prehled/fetch, else
~/.cache/kulturni-prehled/fetch — `pages/<sha256>.{json,body}` and
`hosts/<host>.json`. Every write is atomic, and a host's state is updated
under an exclusive lock, so concurrent scrapers share one budget.

Environment:
    KP_FETCH_REFRESH      comma list of kinds (listing, detail, feed) or "all"
                          whose cached pages count as stale this run — the
                          season run uses it for listings. Budget and cooldown
                          still apply.
    KP_FETCH_FRESH_URLS   file with one URL per line to re-check after
                          WATCH_MAX_AGE instead of their kind's age limit.
    KP_FETCH_CACHE        cache directory (tests, other machines).

CLI (the bash scrapers):
    kp_fetch.py get --kind listing|detail|feed URL   body on stdout; exit 0,
                                                     or 3 when there is none
    kp_fetch.py status [HOST]                        hosts' budget and cooldown
    kp_fetch.py prune                                drop entries unused for a year
                                                     (also done once a day by itself)
Every network decision is logged to stderr as one `KP_FETCH <event> <url>`
line (fetched, not-modified, cached, stale, cooldown, budget, failed).
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

UA = "Mozilla/5.0 (compatible; kp-kulturni-kritik/1.0)"
DAY = 86400.0

# Age limits per kind of page, before the per-URL jitter.
MAX_AGE = {"listing": 28 * DAY, "detail": 28 * DAY, "feed": 6 * DAY}
WATCH_MAX_AGE = 3 * DAY
JITTER = 0.25  # an age limit is shortened by up to this fraction, per URL


@dataclass(frozen=True)
class HostPolicy:
    min_interval: float  # seconds between two requests to the host
    daily_budget: int  # requests in any rolling 24 hours
    timeout: int = 30  # seconds for one request


DEFAULT_POLICY = HostPolicy(min_interval=2.0, daily_budget=80)
HOST_POLICY = {
    # Bans this network after a burst of ~50 requests even at 3 s apart
    # (2026-09-20, 2026-09-27, 2026-10-10). A first fill takes a few runs.
    "www.fok.cz": HostPolicy(min_interval=6.0, daily_budget=25),
    # GoOut renders heavy pages slowly.
    "goout.net": HostPolicy(min_interval=2.0, daily_budget=80, timeout=40),
}

COOLDOWN_BASE = 6 * 3600.0
COOLDOWN_MAX = 7 * DAY
PRUNE_AFTER = 365 * DAY

# curl exit codes that mean the host did not answer, as opposed to a broken
# request on our side: resolve, connect, timeout, TLS handshake, empty reply,
# send / receive failure.
_HOST_FAILURES = {6, 7, 28, 35, 52, 55, 56}


def cache_dir() -> Path:
    explicit = os.environ.get("KP_FETCH_CACHE")
    if explicit:
        return Path(explicit)
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "kulturni-prehled" / "fetch"


def log(event: str, url: str, detail: str = "") -> None:
    print(f"KP_FETCH {event} {url}{' ' + detail if detail else ''}", file=sys.stderr)


def _key(url: str) -> str:
    return hashlib.sha256(url.encode("utf-8")).hexdigest()


def _jitter(url: str) -> float:
    """A stable fraction in [0, 1) per URL."""
    return int(_key(url)[:8], 16) / 0x1_0000_0000


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        return None


@dataclass
class Response:
    status: int  # HTTP status, 0 when the host did not answer
    body: bytes
    headers: dict[str, str]  # lower-cased names, last hop only
    curl_exit: int = 0
    # The sandbox's proxy refused the host (not on the run's allow-list) —
    # the request never left this machine.
    proxy_refused: bool = False


def curl_fetch(url: str, headers: dict[str, str], timeout: int = 30) -> Response:
    """One GET through curl, following redirects."""
    with tempfile.TemporaryDirectory(prefix="kp-fetch-") as tmp:
        head, body = Path(tmp, "head"), Path(tmp, "body")
        cmd = ["curl", "-sS", "-L", "-A", UA, "--max-time", str(timeout)]
        for name, value in headers.items():
            cmd += ["-H", f"{name}: {value}"]
        cmd += ["-D", str(head), "-o", str(body), "-w", "%{http_code}", url]
        try:
            done = subprocess.run(cmd, capture_output=True, timeout=timeout + 15)
        except subprocess.TimeoutExpired:
            return Response(0, b"", {}, curl_exit=28)
        if b"CONNECT tunnel failed" in done.stderr:
            return Response(0, b"", {}, curl_exit=done.returncode, proxy_refused=True)
        code = done.stdout.decode("ascii", "replace").strip()
        status = int(code) if code.isdigit() else 0
        parsed: dict[str, str] = {}
        if head.exists():
            # -L writes one header block per hop; the last one is the answer.
            blocks = head.read_bytes().decode("latin-1").replace("\r\n", "\n").strip().split("\n\n")
            for line in blocks[-1].split("\n")[1:]:
                name, sep, value = line.partition(":")
                if sep:
                    parsed[name.strip().lower()] = value.strip()
        data = body.read_bytes() if body.exists() else b""
        if done.returncode != 0 and status == 0:
            return Response(0, b"", parsed, curl_exit=done.returncode)
        return Response(status, data, parsed, curl_exit=done.returncode)


class Fetcher:
    """The cache, the budget and the cooldown. Injectable clock and network."""

    def __init__(
        self,
        root: Path | None = None,
        *,
        network: Callable[[str, dict[str, str], int], Response] = curl_fetch,
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
        refresh: set[str] | None = None,
        fresh_urls: set[str] | None = None,
    ) -> None:
        self.root = root or cache_dir()
        self.network = network
        self.clock = clock
        self.sleep = sleep
        self.refresh = refresh if refresh is not None else _env_refresh()
        self.fresh_urls = fresh_urls if fresh_urls is not None else _env_fresh_urls()
        self._pruned = False

    # --- pages ---------------------------------------------------------------

    def _page_paths(self, url: str) -> tuple[Path, Path]:
        k = _key(url)
        return self.root / "pages" / f"{k}.json", self.root / "pages" / f"{k}.body"

    def _load(self, url: str) -> tuple[dict[str, Any] | None, bytes | None]:
        meta_path, body_path = self._page_paths(url)
        meta = _read_json(meta_path)
        if meta is None or meta.get("url") != url:
            return None, None
        try:
            body = body_path.read_bytes()
        except FileNotFoundError:
            return None, None
        return meta, body

    def _store(self, url: str, kind: str, resp: Response, now: float) -> None:
        meta_path, body_path = self._page_paths(url)
        _atomic_write(body_path, resp.body)
        meta = {
            "url": url,
            "kind": kind,
            "status": resp.status,
            "fetched_at": now,
            "checked_at": now,
            "etag": resp.headers.get("etag"),
            "last_modified": resp.headers.get("last-modified"),
        }
        _atomic_write(meta_path, json.dumps(meta).encode("utf-8"))

    def _touch(self, url: str, meta: dict[str, Any], resp: Response, now: float) -> None:
        meta = dict(meta, checked_at=now)
        # A 304 may carry a newer validator; keep whatever the server sent.
        for name in ("etag", "last-modified"):
            if resp.headers.get(name):
                meta[name.replace("-", "_")] = resp.headers[name]
        _atomic_write(self._page_paths(url)[0], json.dumps(meta).encode("utf-8"))

    def max_age(self, url: str, kind: str) -> float:
        if "all" in self.refresh or kind in self.refresh:
            return 0.0
        base = WATCH_MAX_AGE if url in self.fresh_urls else MAX_AGE[kind]
        return base * (1.0 - JITTER * _jitter(url))

    # --- hosts ---------------------------------------------------------------

    @contextlib.contextmanager
    def _host(self, host: str) -> Iterator[dict[str, Any]]:
        """The host's state, locked for the duration, written back on exit."""
        path = self.root / "hosts" / f"{host}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.root / "hosts" / f"{host}.lock", "a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            state = _read_json(path) or {}
            state.setdefault("requests", [])
            state.setdefault("strikes", 0)
            state.setdefault("cooldown_until", 0.0)
            yield state
            _atomic_write(path, json.dumps(state).encode("utf-8"))

    def _cool_down(self, state: dict[str, Any], now: float, retry_after: float | None) -> float:
        state["strikes"] = int(state["strikes"]) + 1
        span = min(COOLDOWN_BASE * 2 ** (state["strikes"] - 1), COOLDOWN_MAX)
        if retry_after:
            span = max(span, min(retry_after, COOLDOWN_MAX))
        state["cooldown_until"] = now + span
        return span

    # --- the one entry point -------------------------------------------------

    def get(self, url: str, kind: str) -> bytes | None:
        """The page body, from the cache or the network; None when neither has it."""
        if kind not in MAX_AGE:
            raise ValueError(f"unknown kind {kind!r}")
        host = urlsplit(url).hostname
        if not host:
            raise ValueError(f"not a URL: {url!r}")
        self._maybe_prune()
        meta, cached = self._load(url)
        now = self.clock()
        if meta is not None and now - float(meta["checked_at"]) < self.max_age(url, kind):
            log("cached", url)
            return self._served(meta, cached)

        policy = HOST_POLICY.get(host, DEFAULT_POLICY)
        with self._host(host) as state:
            now = self.clock()
            if now < float(state["cooldown_until"]):
                log("cooldown", url, f"host={host} until={_iso(state['cooldown_until'])}")
                return self._stale(url, meta, cached)
            state["requests"] = [t for t in state["requests"] if now - t < DAY]
            if len(state["requests"]) >= policy.daily_budget:
                log(
                    "budget",
                    url,
                    f"host={host} used={len(state['requests'])}/{policy.daily_budget}",
                )
                return self._stale(url, meta, cached)
            if state["requests"]:
                wait = policy.min_interval - (now - max(state["requests"]))
                if wait > 0:
                    self.sleep(wait)
                    now = self.clock()

            headers: dict[str, str] = {}
            if meta is not None and cached is not None and meta.get("status") == 200:
                if meta.get("etag"):
                    headers["If-None-Match"] = meta["etag"]
                if meta.get("last_modified"):
                    headers["If-Modified-Since"] = meta["last_modified"]
            resp = self.network(url, headers, policy.timeout)
            if resp.proxy_refused:
                # The sandbox, not the host, said no: a redirect to a host
                # missing from infra/claudebox/sandbox-domains.txt, say.
                log(
                    "failed",
                    url,
                    f"host={host} refused by the sandbox proxy (not in its allowed domains)",
                )
                return self._stale(url, meta, cached)
            if resp.status == 0 and resp.curl_exit not in _HOST_FAILURES:
                # curl failed on our side (bad URL, disk, proxy): the host
                # was not asked, so it is neither charged nor cooled down.
                log("failed", url, f"host={host} curl_exit={resp.curl_exit} (local)")
                return self._stale(url, meta, cached)
            state["requests"].append(now)

            if resp.status == 0 or resp.status in (403, 429) or resp.status >= 500:
                retry_after = _retry_after(resp.headers.get("retry-after"))
                span = self._cool_down(state, now, retry_after)
                why = f"curl_exit={resp.curl_exit}" if resp.status == 0 else f"http={resp.status}"
                log("failed", url, f"host={host} {why} cooldown={span / 3600:.0f}h")
                return self._stale(url, meta, cached)

            state["strikes"] = 0
            if resp.status == 304 and meta is not None:
                self._touch(url, meta, resp, now)
                log("not-modified", url)
                return self._served(meta, cached)
            self._store(url, kind, resp, now)
            log("fetched", url, f"http={resp.status}")
            return resp.body if resp.status == 200 else None

    def _served(self, meta: dict[str, Any], body: bytes | None) -> bytes | None:
        # A cached 404 stays an answer ("no such page") until it is re-checked.
        return body if meta.get("status") == 200 else None

    def _stale(self, url: str, meta: dict[str, Any] | None, body: bytes | None) -> bytes | None:
        if meta is None:
            return None
        age = (self.clock() - float(meta["checked_at"])) / DAY
        log("stale", url, f"age={age:.0f}d")
        return self._served(meta, body)

    # --- housekeeping --------------------------------------------------------

    def status(self, host: str | None = None) -> list[dict[str, Any]]:
        out = []
        now = self.clock()
        for path in sorted((self.root / "hosts").glob("*.json")):
            if host and path.stem != host:
                continue
            state = _read_json(path) or {}
            policy = HOST_POLICY.get(path.stem, DEFAULT_POLICY)
            used = len([t for t in state.get("requests", []) if now - t < DAY])
            out.append(
                {
                    "host": path.stem,
                    "requests_24h": used,
                    "daily_budget": policy.daily_budget,
                    "strikes": state.get("strikes", 0),
                    "cooldown_until": _iso(state.get("cooldown_until")),
                    "cooling_down": now < float(state.get("cooldown_until") or 0),
                }
            )
        return out

    def _maybe_prune(self) -> None:
        """Prune at most once a day, on the first request of a process."""
        if self._pruned:
            return
        self._pruned = True
        stamp = self.root / ".pruned_at"
        try:
            last = float(stamp.read_text(encoding="utf-8"))
        except (FileNotFoundError, ValueError):
            last = 0.0
        now = self.clock()
        if now - last >= DAY:
            self.prune()
            _atomic_write(stamp, str(now).encode("ascii"))

    def prune(self) -> int:
        removed = 0
        now = self.clock()
        for meta_path in (self.root / "pages").glob("*.json"):
            meta = _read_json(meta_path)
            if meta is None or now - float(meta.get("checked_at", 0)) > PRUNE_AFTER:
                for path in (meta_path, meta_path.with_suffix(".body")):
                    with contextlib.suppress(FileNotFoundError):
                        path.unlink()
                removed += 1
        return removed


def _iso(epoch: float | None) -> str | None:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch)) if epoch else None


def _retry_after(value: str | None) -> float | None:
    if value and value.strip().isdigit():
        return float(value.strip())
    return None


def _env_refresh() -> set[str]:
    raw = os.environ.get("KP_FETCH_REFRESH", "")
    return {part.strip() for part in raw.split(",") if part.strip()}


def _env_fresh_urls() -> set[str]:
    path = os.environ.get("KP_FETCH_FRESH_URLS")
    if not path:
        return set()
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return set()
    return {line.strip() for line in lines if line.strip() and not line.startswith("#")}


_default: Fetcher | None = None


def get(url: str, kind: str) -> str | None:
    """Module-level shortcut for the Python scrapers: the page as text, or None."""
    global _default
    if _default is None:
        _default = Fetcher()
    body = _default.get(url, kind)
    return None if body is None else body.decode("utf-8", errors="replace")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("get", help="print a page's body")
    g.add_argument("--kind", required=True, choices=sorted(MAX_AGE))
    g.add_argument("url")
    s = sub.add_parser("status", help="hosts' budget and cooldown")
    s.add_argument("host", nargs="?")
    sub.add_parser("prune", help="drop entries unused for a year")
    a = p.parse_args(argv)

    fetcher = Fetcher()
    if a.cmd == "get":
        body = fetcher.get(a.url, a.kind)
        if body is None:
            return 3
        sys.stdout.buffer.write(body)
        return 0
    if a.cmd == "status":
        print(json.dumps(fetcher.status(a.host), indent=2))
        return 0
    print(f"pruned {fetcher.prune()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
