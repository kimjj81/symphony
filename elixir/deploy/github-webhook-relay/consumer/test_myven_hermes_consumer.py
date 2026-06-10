"""Unit tests for the Myven Hermes webhook consumer helpers."""

from __future__ import annotations

import unittest
from subprocess import CompletedProcess
from unittest import mock

from myven_hermes_consumer import build_task_body, extract_tracker_item, reconcile_item


class MyvenHermesConsumerTest(unittest.TestCase):
    def test_pull_request_review_comment_body_includes_comment_context(self) -> None:
        envelope = {
            "event": "pull_request_review_comment",
            "delivery_id": "delivery-1",
            "payload": {
                "action": "created",
                "repository": {"full_name": "studiojin-dev/myven"},
                "sender": {"login": "reviewer-user"},
                "pull_request": {
                    "number": 123,
                    "title": "Improve auth flow",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/123",
                    "labels": [{"name": "hermes:review"}],
                },
                "comment": {
                    "id": 98765,
                    "user": {"login": "codex-bot"},
                    "body": "Please handle this inline review note.",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/123#discussion_r98765",
                    "path": "src/auth.ts",
                    "line": 42,
                    "original_line": 40,
                    "diff_hunk": "@@ -39,7 +39,7 @@\n-old\n+new",
                },
            },
        }

        item = extract_tracker_item(envelope)
        self.assertIsNotNone(item)

        body = build_task_body(item)  # type: ignore[arg-type]

        self.assertIn("Comment URL: https://github.com/studiojin-dev/myven/pull/123#discussion_r98765", body)
        self.assertIn("Comment author: codex-bot", body)
        self.assertIn("Comment body:\nPlease handle this inline review note.", body)
        self.assertIn("Comment path: src/auth.ts", body)
        self.assertIn("Comment line: 42", body)
        self.assertIn("Comment original line: 40", body)
        self.assertIn("Diff hunk:\n@@ -39,7 +39,7 @@\n-old\n+new", body)

    def test_issue_comment_body_includes_comment_context(self) -> None:
        envelope = {
            "event": "issue_comment",
            "delivery_id": "delivery-2",
            "payload": {
                "action": "created",
                "repository": {"full_name": "studiojin-dev/myven"},
                "issue": {
                    "number": 55,
                    "title": "Fix flaky spec",
                    "html_url": "https://github.com/studiojin-dev/myven/issues/55",
                    "labels": [{"name": "hermes:todo"}],
                },
                "comment": {
                    "id": 12345,
                    "user": {"login": "kimjj81"},
                    "body": "이 코멘트도 작업 지시로 봐줘.",
                    "html_url": "https://github.com/studiojin-dev/myven/issues/55#issuecomment-12345",
                },
            },
        }

        item = extract_tracker_item(envelope)
        self.assertIsNotNone(item)

        body = build_task_body(item)  # type: ignore[arg-type]

        self.assertIn("Comment URL: https://github.com/studiojin-dev/myven/issues/55#issuecomment-12345", body)
        self.assertIn("Comment author: kimjj81", body)
        self.assertIn("Comment body:\n이 코멘트도 작업 지시로 봐줘.", body)

    def test_reconcile_uses_configured_hermes_binary(self) -> None:
        envelope = {
            "event": "pull_request",
            "delivery_id": "delivery-3",
            "payload": {
                "action": "labeled",
                "repository": {"full_name": "studiojin-dev/myven"},
                "pull_request": {
                    "number": 297,
                    "title": "Docs PR",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/297",
                    "labels": [{"name": "hermes:human-review"}],
                },
            },
        }
        item = extract_tracker_item(envelope)
        self.assertIsNotNone(item)

        calls: list[list[str]] = []

        def fake_run(command: list[str], cwd: str, dry_run: bool):
            calls.append(command)
            return None

        with mock.patch.dict("os.environ", {"HERMES_BIN": "/tmp/hermes-test"}), mock.patch(
            "myven_hermes_consumer.run_command", side_effect=fake_run
        ):
            reconcile_item(item, dry_run=True)  # type: ignore[arg-type]

        self.assertEqual(calls[0][0], "/tmp/hermes-test")

    def test_reconcile_appends_review_comment_to_idempotent_task(self) -> None:
        envelope = {
            "event": "pull_request_review_comment",
            "delivery_id": "delivery-4",
            "payload": {
                "action": "created",
                "repository": {"full_name": "studiojin-dev/myven"},
                "pull_request": {
                    "number": 297,
                    "title": "Docs PR",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/297",
                    "labels": [{"name": "hermes:review"}],
                },
                "comment": {
                    "id": 3385744203,
                    "user": {"login": "chatgpt-codex-connector[bot]"},
                    "body": "Choose an AA-compliant default button color.",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/297#discussion_r3385744203",
                    "path": "docs/adr/example.md",
                    "line": 62,
                    "diff_hunk": "@@ -61,2 +61,2 @@",
                },
            },
        }
        item = extract_tracker_item(envelope)
        self.assertIsNotNone(item)

        calls: list[list[str]] = []

        def fake_run(command: list[str], cwd: str, dry_run: bool):
            calls.append(command)
            if "create" in command:
                return CompletedProcess(command, 0, stdout='{"id":"t_review297"}', stderr="")
            return CompletedProcess(command, 0, stdout="", stderr="")

        with mock.patch.dict("os.environ", {"HERMES_BIN": "hermes"}), mock.patch(
            "myven_hermes_consumer.run_command", side_effect=fake_run
        ):
            reconcile_item(item, dry_run=False)  # type: ignore[arg-type]

        self.assertIn("--json", calls[0])
        self.assertEqual(calls[1][:5], ["hermes", "kanban", "--board", "myven", "comment"])
        self.assertEqual(calls[1][5], "t_review297")
        self.assertIn(
            "Comment URL: https://github.com/studiojin-dev/myven/pull/297#discussion_r3385744203",
            calls[1][6],
        )
        self.assertIn("Choose an AA-compliant default button color.", calls[1][6])


if __name__ == "__main__":
    unittest.main()
