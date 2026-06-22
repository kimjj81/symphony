"""Unit tests for the Myven Hermes webhook consumer helpers."""

from __future__ import annotations

import unittest
from subprocess import CompletedProcess
from unittest import mock

from myven_hermes_consumer import build_task_body, extract_tracker_item, reconcile_item


class MyvenHermesConsumerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.env_patch = mock.patch.dict("os.environ", {"HERMES_KANBAN_BOARD": "myven"})
        self.env_patch.start()

    def tearDown(self) -> None:
        self.env_patch.stop()

    def test_extract_ignores_mixed_sym_and_hermes_labels_by_default(self) -> None:
        envelope = {
            "event": "pull_request",
            "delivery_id": "delivery-mixed-labels",
            "payload": {
                "action": "labeled",
                "repository": {"full_name": "studiojin-dev/myven"},
                "pull_request": {
                    "number": 286,
                    "title": "Symphony-managed integration PR",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/286",
                    "labels": [{"name": "sym:human-review"}, {"name": "hermes:rework"}],
                    "head": {"ref": "feature/issue-73"},
                },
            },
        }

        self.assertIsNone(extract_tracker_item(envelope))

    def test_extract_ignores_symphony_branch_even_with_hermes_label_by_default(self) -> None:
        envelope = {
            "event": "pull_request",
            "delivery_id": "delivery-symphony-branch",
            "payload": {
                "action": "labeled",
                "repository": {"full_name": "studiojin-dev/myven"},
                "pull_request": {
                    "number": 286,
                    "title": "Symphony-managed integration PR",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/286",
                    "labels": [{"name": "hermes:rework"}],
                    "head": {"ref": "symphony/_73-feature"},
                },
            },
        }

        self.assertIsNone(extract_tracker_item(envelope))

    def test_extract_allows_symphony_branch_only_with_explicit_override(self) -> None:
        envelope = {
            "event": "pull_request",
            "delivery_id": "delivery-symphony-branch-override",
            "payload": {
                "action": "labeled",
                "repository": {"full_name": "studiojin-dev/myven"},
                "pull_request": {
                    "number": 286,
                    "title": "Explicitly migrated integration PR",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/286",
                    "labels": [{"name": "hermes:review"}],
                    "head": {"ref": "symphony/_73-feature"},
                },
            },
        }

        with mock.patch.dict("os.environ", {"ALLOW_HERMES_ON_SYMPHONY_BRANCHES": "true"}):
            item = extract_tracker_item(envelope)

        self.assertIsNotNone(item)
        self.assertEqual(item.state_label, "hermes:review")  # type: ignore[union-attr]

    def test_reconcile_ignores_issue_comment_when_live_pr_head_is_symphony_branch(self) -> None:
        envelope = {
            "event": "issue_comment",
            "delivery_id": "delivery-symphony-branch-comment",
            "payload": {
                "action": "created",
                "repository": {"full_name": "studiojin-dev/myven"},
                "issue": {
                    "number": 286,
                    "title": "Symphony-managed integration PR",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/286",
                    "labels": [{"name": "hermes:rework"}],
                    "pull_request": {"url": "https://api.github.com/repos/studiojin-dev/myven/pulls/286"},
                },
                "comment": {
                    "id": 4718334073,
                    "user": {"login": "kimjj81"},
                    "body": "main merge conflict 해결",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/286#issuecomment-4718334073",
                },
            },
        }
        item = extract_tracker_item(envelope)
        self.assertIsNotNone(item)

        calls: list[list[str]] = []

        def fake_run(command: list[str], cwd: str, dry_run: bool):
            calls.append(command)
            if command[:3] == ["gh", "pr", "view"]:
                return CompletedProcess(command, 0, stdout="symphony/_73-feature\n", stderr="")
            return CompletedProcess(command, 0, stdout='{"id":"t_should_not_create"}', stderr="")

        with mock.patch.dict("os.environ", {"HERMES_BIN": "/tmp/hermes-test", "GH_BIN": "gh"}), mock.patch(
            "myven_hermes_consumer.run_command", side_effect=fake_run
        ):
            reconcile_item(item, dry_run=False)  # type: ignore[arg-type]

        self.assertEqual(calls[0][:6], ["gh", "pr", "view", "286", "--repo", "studiojin-dev/myven"])
        self.assertFalse(any(command[:4] == ["/tmp/hermes-test", "kanban", "--board", "myven"] for command in calls))

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

        with mock.patch.dict("os.environ", {"HERMES_BIN": "/tmp/hermes-test", "GH_BIN": "gh"}), mock.patch(
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
            if command[:4] == ["hermes", "kanban", "--board", "myven"] and "create" in command:
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

    def test_reconcile_auto_subscribes_task_after_creation(self) -> None:
        envelope = {
            "event": "pull_request",
            "delivery_id": "delivery-5",
            "payload": {
                "action": "labeled",
                "repository": {"full_name": "studiojin-dev/myven"},
                "pull_request": {
                    "number": 301,
                    "title": "Add widget",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/301",
                    "labels": [{"name": "hermes:review"}],
                },
            },
        }
        item = extract_tracker_item(envelope)
        self.assertIsNotNone(item)

        calls: list[list[str]] = []

        def fake_run(command: list[str], cwd: str, dry_run: bool):
            calls.append(command)
            if command[:4] == ["/tmp/hermes-test", "kanban", "--board", "myven"] and "create" in command:
                return CompletedProcess(command, 0, stdout='{"id":"t_subscribe"}', stderr="")
            return CompletedProcess(command, 0, stdout="", stderr="")

        with mock.patch.dict(
            "os.environ",
            {
                "HERMES_BIN": "/tmp/hermes-test",
                "TELEGRAM_HOME_CHANNEL": "45656502",
                "TELEGRAM_HOME_CHANNEL_THREAD_ID": "17585",
            },
        ), mock.patch("myven_hermes_consumer.run_command", side_effect=fake_run):
            reconcile_item(item, dry_run=False)  # type: ignore[arg-type]

        self.assertEqual(
            calls[1],
            [
                "/tmp/hermes-test",
                "kanban",
                "--board",
                "myven",
                "notify-subscribe",
                "t_subscribe",
                "--platform",
                "telegram",
                "--chat-id",
                "45656502",
                "--thread-id",
                "17585",
            ],
        )

    def test_reconcile_routes_codex_review_comment_to_rework(self) -> None:
        envelope = {
            "event": "pull_request_review_comment",
            "delivery_id": "delivery-6",
            "payload": {
                "action": "created",
                "repository": {"full_name": "studiojin-dev/myven"},
                "pull_request": {
                    "number": 302,
                    "title": "Needs review fixes",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/302",
                    "labels": [{"name": "hermes:review"}],
                },
                "review": {
                    "id": 5566,
                    "user": {"login": "chatgpt-codex-connector"},
                    "body": "Please address the inline feedback.",
                    "state": "COMMENTED",
                    "submitted_at": "2026-06-10T07:00:00Z",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/302#pullrequestreview-5566",
                },
                "comment": {
                    "id": 3385744203,
                    "user": {"login": "chatgpt-codex-connector[bot]"},
                    "body": "Choose an AA-compliant default button color.",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/302#discussion_r3385744203",
                    "path": "docs/adr/example.md",
                    "line": 62,
                    "diff_hunk": "@@ -61,2 +61,2 @@",
                },
            },
        }
        item = extract_tracker_item(envelope)
        self.assertIsNotNone(item)
        self.assertIn("Review state: COMMENTED", build_task_body(item))  # type: ignore[arg-type]

        calls: list[list[str]] = []

        def fake_run(command: list[str], cwd: str, dry_run: bool):
            calls.append(command)
            if command[:4] == ["/tmp/hermes-test", "kanban", "--board", "myven"] and "create" in command:
                return CompletedProcess(command, 0, stdout='{"id":"t_rework"}', stderr="")
            return CompletedProcess(command, 0, stdout="", stderr="")

        with mock.patch.dict("os.environ", {"HERMES_BIN": "/tmp/hermes-test", "GH_BIN": "gh"}), mock.patch(
            "myven_hermes_consumer.run_command", side_effect=fake_run
        ):
            reconcile_item(item, dry_run=False)  # type: ignore[arg-type]

        self.assertIn(
            [
                "/tmp/hermes-test",
                "kanban",
                "--board",
                "myven",
                "comment",
                "t_rework",
                mock.ANY,
            ],
            calls,
        )
        self.assertIn(
            [
                "gh",
                "issue",
                "edit",
                "302",
                "--repo",
                "studiojin-dev/myven",
                "--remove-label",
                "hermes:review",
                "--add-label",
                "hermes:rework",
            ],
            calls,
        )

    def test_reconcile_routes_codex_rework_review_to_review(self) -> None:
        envelope = {
            "event": "pull_request_review",
            "delivery_id": "delivery-7",
            "payload": {
                "action": "submitted",
                "repository": {"full_name": "studiojin-dev/myven"},
                "pull_request": {
                    "number": 304,
                    "title": "Ready for another review",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/304",
                    "labels": [{"name": "hermes:rework"}],
                },
                "review": {
                    "id": 7799,
                    "user": {"login": "chatgpt-codex-connector"},
                    "body": "Looks good after the fixes.",
                    "state": "APPROVED",
                    "submitted_at": "2026-06-10T07:10:00Z",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/304#pullrequestreview-7799",
                },
            },
        }
        item = extract_tracker_item(envelope)
        self.assertIsNotNone(item)

        calls: list[list[str]] = []

        def fake_run(command: list[str], cwd: str, dry_run: bool):
            calls.append(command)
            if command[:4] == ["/tmp/hermes-test", "kanban", "--board", "myven"] and "create" in command:
                return CompletedProcess(command, 0, stdout='{"id":"t_review"}', stderr="")
            return CompletedProcess(command, 0, stdout="", stderr="")

        with mock.patch.dict("os.environ", {"HERMES_BIN": "/tmp/hermes-test", "GH_BIN": "gh"}), mock.patch(
            "myven_hermes_consumer.run_command", side_effect=fake_run
        ):
            reconcile_item(item, dry_run=False)  # type: ignore[arg-type]

        self.assertTrue(
            any(
                command[:10]
                == [
                    "/tmp/hermes-test",
                    "kanban",
                    "--board",
                    "myven",
                    "create",
                    "hermes:review pr #304: Ready for another review",
                    "--assignee",
                    "reviewer",
                    "--idempotency-key",
                    "myven:pr:304:review",
                ]
                for command in calls
            )
        )
        self.assertIn(
            [
                "gh",
                "issue",
                "edit",
                "304",
                "--repo",
                "studiojin-dev/myven",
                "--remove-label",
                "hermes:rework",
                "--add-label",
                "hermes:review",
            ],
            calls,
        )

    def test_reconcile_routes_codex_review_approval_to_human_review(self) -> None:
        envelope = {
            "event": "pull_request_review",
            "delivery_id": "delivery-8",
            "payload": {
                "action": "submitted",
                "repository": {"full_name": "studiojin-dev/myven"},
                "pull_request": {
                    "number": 303,
                    "title": "Ready for human review",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/303",
                    "labels": [{"name": "hermes:review"}],
                },
                "review": {
                    "id": 7788,
                    "user": {"login": "chatgpt-codex-connector"},
                    "body": "LGTM.",
                    "state": "APPROVED",
                    "submitted_at": "2026-06-10T07:10:00Z",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/303#pullrequestreview-7788",
                },
            },
        }
        item = extract_tracker_item(envelope)
        self.assertIsNotNone(item)

        calls: list[list[str]] = []

        def fake_run(command: list[str], cwd: str, dry_run: bool):
            calls.append(command)
            if command[:4] == ["/tmp/hermes-test", "kanban", "--board", "myven"] and "create" in command:
                return CompletedProcess(command, 0, stdout='{"id":"t_review_approve"}', stderr="")
            return CompletedProcess(command, 0, stdout="", stderr="")

        with mock.patch.dict("os.environ", {"HERMES_BIN": "/tmp/hermes-test", "GH_BIN": "gh"}), mock.patch(
            "myven_hermes_consumer.run_command", side_effect=fake_run
        ):
            reconcile_item(item, dry_run=False)  # type: ignore[arg-type]

        self.assertIn(
            [
                "gh",
                "issue",
                "edit",
                "303",
                "--repo",
                "studiojin-dev/myven",
                "--remove-label",
                "hermes:review",
                "--add-label",
                "hermes:human-review",
            ],
            calls,
        )

    def test_reconcile_syncs_human_review_label_and_comment_for_blocked_items(self) -> None:
        envelope = {
            "event": "pull_request",
            "delivery_id": "delivery-6",
            "payload": {
                "action": "labeled",
                "repository": {"full_name": "studiojin-dev/myven"},
                "pull_request": {
                    "number": 302,
                    "title": "Needs attention",
                    "html_url": "https://github.com/studiojin-dev/myven/pull/302",
                    "labels": [{"name": "hermes:waiting"}],
                },
            },
        }
        item = extract_tracker_item(envelope)
        self.assertIsNotNone(item)

        calls: list[list[str]] = []

        def fake_run(command: list[str], cwd: str, dry_run: bool):
            calls.append(command)
            if command[:4] == ["/tmp/hermes-test", "kanban", "--board", "myven"] and "create" in command:
                return CompletedProcess(command, 0, stdout='{"id":"t_blocked"}', stderr="")
            if command[:2] == ["gh", "api"]:
                return CompletedProcess(command, 0, stdout="[]", stderr="")
            if command[:3] == ["gh", "issue", "edit"]:
                return CompletedProcess(command, 0, stdout="", stderr="")
            if command[:3] == ["gh", "issue", "comment"]:
                return CompletedProcess(command, 0, stdout="", stderr="")
            return CompletedProcess(command, 0, stdout="", stderr="")

        with mock.patch.dict(
            "os.environ",
            {
                "HERMES_BIN": "/tmp/hermes-test",
                "GH_BIN": "gh",
            },
        ), mock.patch("myven_hermes_consumer.run_command", side_effect=fake_run):
            reconcile_item(item, dry_run=False)  # type: ignore[arg-type]

        self.assertIn(
            [
                "gh",
                "issue",
                "edit",
                "302",
                "--repo",
                "studiojin-dev/myven",
                "--remove-label",
                "hermes:waiting",
                "--add-label",
                "hermes:human-review",
            ],
            calls,
        )
        comment_calls = [command for command in calls if command[:3] == ["gh", "issue", "comment"]]
        self.assertEqual(len(comment_calls), 1)
        self.assertEqual(
            comment_calls[0][:7],
            ["gh", "issue", "comment", "302", "--repo", "studiojin-dev/myven", "--body"],
        )
        self.assertIn("Delivery: delivery-6", comment_calls[0][7])
        self.assertIn("Kanban task: t_blocked", comment_calls[0][7])


if __name__ == "__main__":
    unittest.main()
