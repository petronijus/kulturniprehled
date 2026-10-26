#!/usr/bin/env python3
"""Google Play Developer API helper: release Kulturní Přehled to a testing track.

    scripts/play.py upload <app-release.aab> [--track internal] [--notes "…"]
    scripts/play.py tracks                   what each track serves now

One upload is one Play "edit": the bundle, the track's new release, a commit.
An edit that fails before its commit changes nothing on Play.

The service account may only release to testing tracks, never to production.
Its JSON key comes from 1Password (item `Kulturni Prehled Play release service
account`, field `service_account_json`, vault Personal), or from
KP_PLAY_SERVICE_ACCOUNT on a box without 1Password. It is never printed and
never written to disk: the private key reaches `openssl` through a pipe.

Stdlib only, like the other scripts outside the API; the RS256 signature of
the token grant comes from the `openssl` CLI.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, NoReturn

PACKAGE = "com.kulturniprehled.kp_mobile"
API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
TRACKS = ("internal", "alpha", "beta")  # testing tracks; production is not this tool's
PUBSPEC = Path(__file__).resolve().parents[1] / "apps/mobile/pubspec.yaml"


def fail(message: str) -> NoReturn:
    sys.exit(f"play: {message}")


def parse_service_account(raw: str) -> dict[str, Any]:
    try:
        account = json.loads(raw)
    except json.JSONDecodeError:
        fail("the service account is not JSON")
    if not isinstance(account, dict):
        fail("the service account is not a JSON object")
    for key in ("client_email", "private_key", "token_uri"):
        if not account.get(key):
            fail(f"the service account has no {key}")
    return account


def service_account() -> dict[str, Any]:
    raw = os.environ.get("KP_PLAY_SERVICE_ACCOUNT")
    if not raw:
        item = os.environ.get("KP_PLAY_ITEM", "Kulturni Prehled Play release service account")
        vault = os.environ.get("OP_VAULT", "Personal")
        try:
            raw = subprocess.run(
                [
                    "op",
                    "read",
                    "--account",
                    os.environ.get("OP_ACCOUNT", "my"),
                    f"op://{vault}/{item}/service_account_json",
                ],
                capture_output=True,
                text=True,
                check=True,
            ).stdout
        except FileNotFoundError:
            fail(
                "no service account: install the 1Password CLI (op) or set KP_PLAY_SERVICE_ACCOUNT"
            )
        except subprocess.CalledProcessError as e:
            fail(f"could not read the service account from 1Password: {e.stderr.strip()}")
    return parse_service_account(raw)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def rs256(message: bytes, private_key_pem: str) -> bytes:
    """Sign with `openssl`; the key goes through a pipe, never a file."""
    key = private_key_pem.encode()
    read_fd, write_fd = os.pipe()
    try:
        # A PEM key is ~1.7 kB, far below the pipe buffer, so this cannot block.
        os.write(write_fd, key)
        os.close(write_fd)
        write_fd = -1
        try:
            result = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", f"/dev/fd/{read_fd}"],
                input=message,
                capture_output=True,
                pass_fds=(read_fd,),
            )
        except FileNotFoundError:
            fail("openssl is not installed")
    finally:
        os.close(read_fd)
        if write_fd >= 0:
            os.close(write_fd)
    if result.returncode != 0 or not result.stdout:
        # stderr names the failure (bad key format); it never echoes the key.
        fail(f"openssl could not sign the token grant: {result.stderr.decode().strip()}")
    return result.stdout


def grant_assertion(account: dict[str, Any], now: int) -> str:
    """The RFC 7523 JWT that trades for an access token."""
    header = {"alg": "RS256", "typ": "JWT", "kid": account.get("private_key_id", "")}
    claims = {
        "iss": account["client_email"],
        "scope": SCOPE,
        "aud": account["token_uri"],
        "iat": now,
        "exp": now + 3600,
    }
    signing_input = ".".join(
        b64url(json.dumps(part, separators=(",", ":")).encode()) for part in (header, claims)
    )
    return f"{signing_input}.{b64url(rs256(signing_input.encode(), account['private_key']))}"


def release_body(track: str, version_code: int, name: str, notes: str) -> dict[str, Any]:
    """The track with a single completed release: it replaces what the track serves."""
    release: dict[str, Any] = {
        "name": name,
        "versionCodes": [str(version_code)],
        "status": "completed",
    }
    if notes:
        release["releaseNotes"] = [{"language": "en-US", "text": notes}]
    return {"track": track, "releases": [release]}


def version_from_pubspec(pubspec: Path = PUBSPEC) -> tuple[str, int]:
    for line in pubspec.read_text().splitlines():
        if line.startswith("version:"):
            name, _, code = line.split(":", 1)[1].strip().partition("+")
            if not code.isdigit():
                fail(f"{pubspec}: version {name!r} has no +build number")
            return name, int(code)
    fail(f"no version in {pubspec}")


def error_message(status: int, body: bytes) -> str:
    try:
        return str(json.loads(body)["error"]["message"])
    except (ValueError, KeyError, TypeError):
        return body.decode(errors="replace")[:300] or f"HTTP {status}"


class Play:
    def __init__(self) -> None:
        account = service_account()
        form = urllib.parse.urlencode(
            {
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": grant_assertion(account, int(time.time())),
            }
        ).encode()
        try:
            with urllib.request.urlopen(account["token_uri"], data=form, timeout=30) as r:
                token = json.load(r)["access_token"]
        except urllib.error.HTTPError as e:
            fail(f"token exchange refused: HTTP {e.code}: {error_message(e.code, e.read())}")
        except urllib.error.URLError as e:
            fail(f"token exchange failed: {e.reason}")
        self.token = token

    def call(
        self,
        method: str,
        url: str,
        body: dict[str, Any] | None = None,
        data: bytes | None = None,
        timeout: int = 60,
    ) -> dict[str, Any]:
        headers = {"Authorization": f"Bearer {self.token}"}
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        elif data is not None:
            headers["Content-Type"] = "application/octet-stream"
        elif method == "POST":
            data = b""
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        where = url.split("/applications/")[-1]
        try:
            with urllib.request.urlopen(request, timeout=timeout) as r:
                content = r.read()
        except urllib.error.HTTPError as e:
            fail(f"{method} {where}: HTTP {e.code}: {error_message(e.code, e.read())}")
        except urllib.error.URLError as e:
            fail(f"{method} {where}: {e.reason}")
        return json.loads(content) if content else {}

    def edit(self) -> str:
        return str(self.call("POST", f"{API}/{PACKAGE}/edits", body={})["id"])


def cmd_upload(args: argparse.Namespace) -> int:
    bundle = Path(args.bundle)
    if not bundle.is_file():
        fail(f"{bundle}: no such bundle")
    name, code = version_from_pubspec()
    play = Play()
    edit = play.edit()
    print(f"uploading {bundle.name} ({bundle.stat().st_size // 1_000_000} MB) as {name} ({code}) …")
    uploaded = play.call(
        "POST",
        f"{UPLOAD}/{PACKAGE}/edits/{edit}/bundles?uploadType=media",
        data=bundle.read_bytes(),
        timeout=600,
    )
    if int(uploaded["versionCode"]) != code:
        fail(
            f"the bundle is version code {uploaded['versionCode']}, pubspec says {code}; rebuild it"
        )
    play.call(
        "PUT",
        f"{API}/{PACKAGE}/edits/{edit}/tracks/{args.track}",
        body=release_body(args.track, code, f"{name} ({code})", args.notes),
    )
    play.call("POST", f"{API}/{PACKAGE}/edits/{edit}:commit")
    print(f"released {name} ({code}) to the {args.track} track")
    return 0


def cmd_tracks(_: argparse.Namespace) -> int:
    play = Play()
    edit = play.edit()
    for track in play.call("GET", f"{API}/{PACKAGE}/edits/{edit}/tracks").get("tracks", []):
        for release in track.get("releases", []):
            codes = ",".join(release.get("versionCodes", []))
            print(f"{track['track']}\t{release.get('name', '?')}\t{release.get('status')}\t{codes}")
    # Reading needs an edit too; drop it uncommitted, it changes nothing.
    play.call("DELETE", f"{API}/{PACKAGE}/edits/{edit}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("upload", help="release a bundle to a testing track")
    p.add_argument("bundle")
    p.add_argument("--track", choices=TRACKS, default="internal")
    p.add_argument("--notes", default="", help="release notes (English)")
    p.set_defaults(run=cmd_upload)
    sub.add_parser("tracks", help="what each track serves").set_defaults(run=cmd_tracks)
    args = parser.parse_args()
    return int(args.run(args))


if __name__ == "__main__":
    sys.exit(main())
