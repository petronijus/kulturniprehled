#!/usr/bin/env python3
"""Tests for kp_fetch: a cached page costs no request, a stale one costs a
conditional request, and a host that refuses is left alone.

Stdlib only and runnable on its own (`python3 test_kp_fetch.py`), the same
deal as test_kp_validate.py — the claudebox has no pytest. The network is a
fake with a clock; the last test drives the real `curl` against a local HTTP
server for the ETag round trip and the CLI.
"""

from __future__ import annotations

import http.server
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
from typing import ClassVar

HERE = pathlib.Path(__file__).parent
spec = importlib.util.spec_from_file_location("kp_fetch", HERE / "kp_fetch.py")
assert spec is not None and spec.loader is not None
kf = importlib.util.module_from_spec(spec)
sys.modules["kp_fetch"] = kf
spec.loader.exec_module(kf)

DAY = kf.DAY
FOK = "https://www.fok.cz/cs/program?page=0"
CF = "https://www.ceskafilharmonie.cz/program"
passed = 0


def ok(name: str) -> None:
    global passed
    passed += 1
    print(f"ok   - {name}")


class Clock:
    def __init__(self) -> None:
        self.now = 1_800_000_000.0
        self.slept: list[float] = []

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.now += seconds


class Net:
    """A scripted network: answers are popped per call, requests recorded."""

    def __init__(self, *answers: kf.Response) -> None:
        self.answers = list(answers)
        self.calls: list[tuple[str, dict[str, str]]] = []
        self.timeouts: list[int] = []

    def __call__(self, url: str, headers: dict[str, str], timeout: int) -> kf.Response:
        self.calls.append((url, dict(headers)))
        self.timeouts.append(timeout)
        if self.answers:
            return self.answers.pop(0)
        return kf.Response(200, b"<html>default</html>", {})


def page(body: bytes = b"<html>v1</html>", etag: str | None = '"v1"') -> kf.Response:
    return kf.Response(200, body, {"etag": etag} if etag else {})


def fetcher(root: pathlib.Path, net: Net, clock: Clock, **kw: object) -> kf.Fetcher:
    kw.setdefault("refresh", set())
    kw.setdefault("fresh_urls", set())
    return kf.Fetcher(root, network=net, clock=clock, sleep=clock.sleep, **kw)  # type: ignore[arg-type]


def case(fn):
    def run() -> None:
        with tempfile.TemporaryDirectory() as d:
            fn(pathlib.Path(d))

    run.__name__ = fn.__name__
    return run


@case
def test_fresh_page_costs_nothing(root: pathlib.Path) -> None:
    clock, net = Clock(), Net(page())
    f = fetcher(root, net, clock)
    assert f.get(FOK, "listing") == b"<html>v1</html>"
    clock.now += 20 * DAY  # inside even the shortest jittered age (21 days)
    assert f.get(FOK, "listing") == b"<html>v1</html>"
    assert len(net.calls) == 1, net.calls
    ok("a page younger than its kind's age is served without a request")


@case
def test_stale_page_is_revalidated(root: pathlib.Path) -> None:
    clock, net = Clock(), Net(page(), kf.Response(304, b"", {"etag": '"v1"'}))
    f = fetcher(root, net, clock)
    f.get(FOK, "listing")
    clock.now += 29 * DAY
    assert f.get(FOK, "listing") == b"<html>v1</html>"
    assert net.calls[1][1] == {"If-None-Match": '"v1"'}, net.calls[1]
    clock.now += 20 * DAY  # the 304 renewed the page's age
    f.get(FOK, "listing")
    assert len(net.calls) == 2
    ok("a stale page costs one conditional request; 304 keeps the body and renews it")


@case
def test_changed_page_replaces_the_cache(root: pathlib.Path) -> None:
    clock, net = Clock(), Net(page(), page(b"<html>v2</html>", '"v2"'))
    f = fetcher(root, net, clock)
    f.get(FOK, "listing")
    clock.now += 29 * DAY
    assert f.get(FOK, "listing") == b"<html>v2</html>"
    clock.now += 1
    assert f.get(FOK, "listing") == b"<html>v2</html>" and len(net.calls) == 2
    ok("a changed page replaces the cached body")


def test_jitter_is_stable_and_bounded() -> None:
    f = kf.Fetcher(pathlib.Path("/nonexistent"), refresh=set(), fresh_urls=set())
    ages = [f.max_age(f"https://www.fok.cz/x/{i}", "detail") for i in range(200)]
    assert all(21 * DAY <= a <= 28 * DAY for a in ages)
    assert max(ages) - min(ages) > 5 * DAY, "ages are not spread"
    assert f.max_age("https://www.fok.cz/x/7", "detail") == ages[7]
    ok("age limits are spread 0-25 % below the kind's, stable per URL")


def test_refresh_and_watched_urls() -> None:
    f = kf.Fetcher(pathlib.Path("/nonexistent"), refresh={"listing"}, fresh_urls={CF})
    assert f.max_age(FOK, "listing") == 0.0
    assert f.max_age(FOK, "detail") > 20 * DAY
    assert f.max_age(CF, "detail") <= kf.WATCH_MAX_AGE
    assert (
        kf.Fetcher(pathlib.Path("/x"), refresh={"all"}, fresh_urls=set()).max_age(CF, "feed") == 0.0
    )
    ok("KP_FETCH_REFRESH makes a kind stale; watched URLs get the short age")


@case
def test_budget_holds_across_fetchers(root: pathlib.Path) -> None:
    clock, net = Clock(), Net()
    budget = kf.HOST_POLICY["www.fok.cz"].daily_budget
    for i in range(budget):
        # a new Fetcher per page, the way the bash scrapers call the CLI
        fetcher(root, net, clock).get(f"https://www.fok.cz/p/{i}", "detail")
    assert len(net.calls) == budget
    assert fetcher(root, net, clock).get("https://www.fok.cz/p/new", "detail") is None
    assert len(net.calls) == budget, "the budget was exceeded"
    fetcher(root, net, clock).get(CF, "listing")
    assert len(net.calls) == budget + 1, "another host was blocked by fok's budget"
    clock.now += DAY
    assert fetcher(root, net, clock).get("https://www.fok.cz/p/new", "detail") is not None
    ok("the per-host daily budget holds across processes and frees after 24 h")


@case
def test_minimum_gap_between_requests(root: pathlib.Path) -> None:
    clock, net = Clock(), Net()
    f = fetcher(root, net, clock)
    f.get("https://www.fok.cz/a", "detail")
    clock.now += 1.5
    f.get("https://www.fok.cz/b", "detail")
    assert clock.slept == [kf.HOST_POLICY["www.fok.cz"].min_interval - 1.5], clock.slept
    f.get("https://www.fok.cz/a", "detail")  # cached: no request, no wait
    assert len(clock.slept) == 1
    ok("requests to one host keep the minimum gap; cache hits do not wait")


@case
def test_refusal_cools_the_host_down(root: pathlib.Path) -> None:
    clock = Clock()
    net = Net(
        page(), kf.Response(0, b"", {}, curl_exit=28), kf.Response(0, b"", {}, curl_exit=7), page()
    )
    f = fetcher(root, net, clock)
    f.get(FOK, "listing")
    clock.now += 29 * DAY
    # the host stops answering: the stale copy is served and the host closed
    assert f.get(FOK, "listing") == b"<html>v1</html>"
    assert fetcher(root, net, clock).get("https://www.fok.cz/other", "detail") is None
    assert len(net.calls) == 2, "a request reached a host in cooldown"
    clock.now += 6 * 3600 + 1
    f.get("https://www.fok.cz/other", "detail")  # refused again: 12 h now
    clock.now += 6 * 3600 + 1
    assert fetcher(root, net, clock).get("https://www.fok.cz/third", "detail") is None
    assert len(net.calls) == 3
    clock.now += 6 * 3600
    assert fetcher(root, net, clock).get("https://www.fok.cz/third", "detail") is not None
    state = json.loads((root / "hosts" / "www.fok.cz.json").read_text())
    assert state["strikes"] == 0, "a success did not reset the strikes"
    ok("a refusal closes the host for 6 h, doubling on repeat; success resets it")


@case
def test_http_refusals_and_retry_after(root: pathlib.Path) -> None:
    clock = Clock()
    net = Net(kf.Response(429, b"slow down", {"retry-after": "172800"}))
    f = fetcher(root, net, clock)
    assert f.get(CF, "listing") is None
    state = json.loads((root / "hosts" / "www.ceskafilharmonie.cz.json").read_text())
    assert state["cooldown_until"] == clock.now + 172800, state
    for status in (403, 503):
        with tempfile.TemporaryDirectory() as d:
            n = Net(kf.Response(status, b"", {}))
            fetcher(pathlib.Path(d), n, Clock()).get(CF, "listing")
            st = json.loads(
                (pathlib.Path(d) / "hosts" / "www.ceskafilharmonie.cz.json").read_text()
            )
            assert st["strikes"] == 1, status
    ok("403, 429 and 5xx cool a host down; a longer Retry-After wins")


@case
def test_local_curl_failure_spares_the_host(root: pathlib.Path) -> None:
    clock, net = Clock(), Net(kf.Response(0, b"", {}, curl_exit=23), page())
    f = fetcher(root, net, clock)
    assert f.get(CF, "listing") is None
    state = json.loads((root / "hosts" / "www.ceskafilharmonie.cz.json").read_text())
    assert state["strikes"] == 0 and state["requests"] == [], state
    assert f.get(CF, "listing") is not None
    ok("a failure on our side (curl exit 23) neither charges nor cools the host")


@case
def test_sandbox_proxy_refusal_spares_the_host(root: pathlib.Path) -> None:
    clock = Clock()
    net = Net(kf.Response(0, b"", {}, curl_exit=56, proxy_refused=True), page())
    f = fetcher(root, net, clock)
    assert f.get("https://www.berg.cz/", "listing") is None
    state = json.loads((root / "hosts" / "www.berg.cz.json").read_text())
    assert state["strikes"] == 0 and state["requests"] == [], state
    assert f.get("https://www.berg.cz/", "listing") is not None
    ok("a refusal by the sandbox proxy neither charges nor cools the host")


@case
def test_timeout_per_host(root: pathlib.Path) -> None:
    clock, net = Clock(), Net()
    f = fetcher(root, net, clock)
    f.get("https://goout.net/cs/praha/akce/", "feed")
    f.get(CF, "listing")
    assert net.timeouts == [40, 30], net.timeouts
    ok("each host gets its own request timeout (GoOut is slow)")


@case
def test_missing_page_is_an_answer(root: pathlib.Path) -> None:
    clock, net = Clock(), Net(kf.Response(404, b"not found", {}))
    f = fetcher(root, net, clock)
    assert f.get("https://www.berg.cz/261301.html", "detail") is None
    assert f.get("https://www.berg.cz/261301.html", "detail") is None
    assert len(net.calls) == 1
    state = json.loads((root / "hosts" / "www.berg.cz.json").read_text())
    assert state["strikes"] == 0
    ok("a 404 is cached as 'no such page' and does not cool the host down")


@case
def test_prune_drops_long_unused_pages(root: pathlib.Path) -> None:
    clock, net = Clock(), Net()
    f = fetcher(root, net, clock)
    f.get("https://www.berg.cz/old.html", "detail")
    clock.now += 200 * DAY
    f.get("https://www.berg.cz/new.html", "detail")
    clock.now += 200 * DAY
    assert f.prune() == 1
    assert f._load("https://www.berg.cz/new.html")[0] is not None
    assert f._load("https://www.berg.cz/old.html")[0] is None
    ok("pages unused for a year are pruned, recent ones kept")


class _Server(http.server.BaseHTTPRequestHandler):
    hits: ClassVar[list[str]] = []

    def do_GET(self) -> None:
        _Server.hits.append(self.headers.get("If-None-Match") or "")
        if self.path == "/gone":
            self.send_response(404)
            self.end_headers()
            return
        if self.headers.get("If-None-Match") == '"abc"':
            self.send_response(304)
            self.send_header("ETag", '"abc"')
            self.end_headers()
            return
        body = "<html>čau</html>".encode()
        self.send_response(200)
        self.send_header("ETag", '"abc"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args: object) -> None:
        pass


def test_real_curl_and_cli() -> None:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        with tempfile.TemporaryDirectory() as d:
            env = dict(os.environ, KP_FETCH_CACHE=d, KP_FETCH_REFRESH="", NO_PROXY="127.0.0.1")

            def cli(*args: str) -> subprocess.CompletedProcess[bytes]:
                return subprocess.run(
                    [sys.executable, str(HERE / "kp_fetch.py"), *args], env=env, capture_output=True
                )

            first = cli("get", "--kind", "detail", f"{base}/page")
            assert first.returncode == 0 and first.stdout.decode() == "<html>čau</html>", first
            assert b"KP_FETCH fetched" in first.stderr
            again = cli("get", "--kind", "detail", f"{base}/page")
            assert again.stdout == first.stdout and b"KP_FETCH cached" in again.stderr
            env["KP_FETCH_REFRESH"] = "detail"
            revalidated = cli("get", "--kind", "detail", f"{base}/page")
            assert revalidated.stdout == first.stdout, revalidated
            assert b"KP_FETCH not-modified" in revalidated.stderr, revalidated.stderr
            assert _Server.hits == ["", '"abc"'], _Server.hits
            gone = cli("get", "--kind", "detail", f"{base}/gone")
            assert gone.returncode == 3 and gone.stdout == b""
            status = json.loads(cli("status").stdout)
            assert status[0]["host"] == "127.0.0.1" and status[0]["requests_24h"] == 3, status
    finally:
        server.shutdown()
    ok("real curl: download, cache hit, 304 revalidation, 404 exit 3, status")


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print(f"{passed} passed")
