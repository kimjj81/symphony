"""Unit tests for the Myven Hermes webhook consumer helpers."""

from __future__ import annotations

import unittest

from myven_hermes_consumer import build_task_body, extract_tracker_item


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


if __name__ == "__main__":
    unittest.main()
