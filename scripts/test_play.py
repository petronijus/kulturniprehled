#!/usr/bin/env python3
"""Tests for scripts/play.py (`python3 scripts/test_play.py`).

Stdlib only, like the other script tests. Nothing here talks to Google: the
token grant is checked against a throwaway RSA key with `openssl` itself.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("play", Path(__file__).with_name("play.py"))
assert spec and spec.loader
play = importlib.util.module_from_spec(spec)
spec.loader.exec_module(play)


def unb64url(part: str) -> bytes:
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


class GrantAssertionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._tmp = tempfile.TemporaryDirectory()
        tmp = Path(cls._tmp.name)
        cls.key = tmp / "key.pem"
        cls.pub = tmp / "pub.pem"
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "RSA", "-out", str(cls.key)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["openssl", "pkey", "-in", str(cls.key), "-pubout", "-out", str(cls.pub)],
            check=True,
            capture_output=True,
        )
        cls.account = {
            "client_email": "release@example.iam.gserviceaccount.com",
            "private_key": cls.key.read_text(),
            "private_key_id": "kid-1",
            "token_uri": "https://oauth2.example.com/token",
        }

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmp.cleanup()

    def test_claims_and_header(self) -> None:
        header, claims, _ = play.grant_assertion(self.account, 1000).split(".")
        self.assertEqual(
            json.loads(unb64url(header)), {"alg": "RS256", "typ": "JWT", "kid": "kid-1"}
        )
        self.assertEqual(
            json.loads(unb64url(claims)),
            {
                "iss": "release@example.iam.gserviceaccount.com",
                "scope": "https://www.googleapis.com/auth/androidpublisher",
                "aud": "https://oauth2.example.com/token",
                "iat": 1000,
                "exp": 4600,
            },
        )

    def test_signature_verifies_with_the_public_key(self) -> None:
        token = play.grant_assertion(self.account, 1000)
        signing_input, _, signature = token.rpartition(".")
        sig = Path(self._tmp.name) / "sig.bin"
        sig.write_bytes(unb64url(signature))
        verify = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", str(self.pub), "-signature", str(sig)],
            input=signing_input.encode(),
            capture_output=True,
        )
        self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)

    def test_a_bad_key_fails_loudly(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            play.rs256(b"x", "-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----\n")
        self.assertIn("openssl could not sign", str(raised.exception.code))


class ServiceAccountTest(unittest.TestCase):
    def test_accepts_a_complete_account(self) -> None:
        raw = json.dumps({"client_email": "a", "private_key": "b", "token_uri": "c"})
        self.assertEqual(play.parse_service_account(raw)["client_email"], "a")

    def test_rejects_non_json(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            play.parse_service_account("not json")
        self.assertIn("not JSON", str(raised.exception.code))

    def test_rejects_a_missing_field(self) -> None:
        raw = json.dumps({"client_email": "a", "private_key": "", "token_uri": "c"})
        with self.assertRaises(SystemExit) as raised:
            play.parse_service_account(raw)
        self.assertIn("no private_key", str(raised.exception.code))


class ReleaseBodyTest(unittest.TestCase):
    def test_completed_release_with_notes(self) -> None:
        self.assertEqual(
            play.release_body("internal", 23, "1.3.0 (23)", "Event notifications"),
            {
                "track": "internal",
                "releases": [
                    {
                        "name": "1.3.0 (23)",
                        "versionCodes": ["23"],
                        "status": "completed",
                        "releaseNotes": [{"language": "en-US", "text": "Event notifications"}],
                    }
                ],
            },
        )

    def test_no_notes_no_release_notes(self) -> None:
        release = play.release_body("internal", 23, "1.3.0 (23)", "")["releases"][0]
        self.assertNotIn("releaseNotes", release)


class PubspecTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.pubspec = Path(self._tmp.name) / "pubspec.yaml"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_name_and_code(self) -> None:
        self.pubspec.write_text("name: kp_mobile\nversion: 1.3.0+23\n")
        self.assertEqual(play.version_from_pubspec(self.pubspec), ("1.3.0", 23))

    def test_missing_build_number(self) -> None:
        self.pubspec.write_text("version: 1.3.0\n")
        with self.assertRaises(SystemExit) as raised:
            play.version_from_pubspec(self.pubspec)
        self.assertIn("no +build number", str(raised.exception.code))

    def test_the_repo_pubspec_parses(self) -> None:
        name, code = play.version_from_pubspec()
        self.assertTrue(name)
        self.assertGreater(code, 0)


class ErrorMessageTest(unittest.TestCase):
    def test_google_error_shape(self) -> None:
        body = json.dumps({"error": {"message": "APK specifies a version code already used"}})
        self.assertEqual(
            play.error_message(403, body.encode()), "APK specifies a version code already used"
        )

    def test_plain_body(self) -> None:
        self.assertEqual(play.error_message(502, b"Bad Gateway"), "Bad Gateway")

    def test_empty_body(self) -> None:
        self.assertEqual(play.error_message(500, b""), "HTTP 500")


if __name__ == "__main__":
    unittest.main()
