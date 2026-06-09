"""Unit tests for the GitHub webhook relay helpers."""

from __future__ import annotations

import hashlib
import hmac
import unittest

from app import build_subject, verify_github_signature


class RelayHelperTest(unittest.TestCase):
    def test_verify_github_signature_accepts_valid_signature(self) -> None:
        secret = "test-secret"
        body = b'{"ok":true}'
        digest = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()

        self.assertTrue(verify_github_signature(secret, body, f"sha256={digest}"))

    def test_verify_github_signature_rejects_invalid_signature(self) -> None:
        self.assertFalse(verify_github_signature("test-secret", b"body", "sha256=bad"))

    def test_verify_github_signature_allows_empty_secret_for_local_tests(self) -> None:
        self.assertTrue(verify_github_signature("", b"body", None))

    def test_build_subject_sanitizes_event_name(self) -> None:
        self.assertEqual(build_subject("github.webhook", "pull_request"), "github.webhook.pull-request")
        self.assertEqual(build_subject("github.webhook", "../bad"), "github.webhook.bad")


if __name__ == "__main__":
    unittest.main()
