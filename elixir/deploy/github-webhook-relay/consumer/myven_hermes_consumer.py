"""Mac-side Hermes Kanban consumer for Myven GitHub webhook events.

The consumer subscribes to NATS JetStream, filters for `studiojin-dev/myven`
items carrying `hermes:*` labels, then reconciles them into the Hermes Kanban
board `myven`.

It defaults to dry-run mode. Set DRY_RUN=false after validating event flow.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shlex
import shutil
import subprocess
from dataclasses import dataclass, replace
from typing import Any

from nats.aio.client import Client as NATS
from nats.errors import TimeoutError as NatsTimeoutError
try:
    from nats.js.errors import FetchTimeoutError
except ImportError:  # pragma: no cover - compatibility with older nats-py releases
    FetchTimeoutError = NatsTimeoutError  # type: ignore[misc,assignment]

JETSTREAM_TIMEOUT_ERRORS = (FetchTimeoutError, NatsTimeoutError)

LOGGER = logging.getLogger("myven_hermes_consumer")

ACTIVE_HERMES_LABELS = {
    "hermes:todo",
    "hermes:planned",
    "hermes:in-progress",
    "hermes:review",
    "hermes:reviewing",
    "hermes:rework",
    "hermes:waiting",
    "hermes:human-review",
    "hermes:merging",
}
TERMINAL_HERMES_LABELS = {"hermes:done", "hermes:canceled", "hermes:duplicate"}
ALL_HERMES_LABELS = ACTIVE_HERMES_LABELS | TERMINAL_HERMES_LABELS
HUMAN_REVIEW_LABEL = "hermes:human-review"
REVIEW_LABEL = "hermes:review"
SYMPHONY_LABEL_PREFIX = "sym:"
SYMPHONY_BRANCH_PREFIX = "symphony/"


@dataclass(frozen=True)
class CommentContext:
    """GitHub comment/review-comment details useful for Kanban workers."""

    id: int | None
    author: str | None
    url: str
    body: str
    path: str
    line: int | None
    original_line: int | None
    diff_hunk: str


@dataclass(frozen=True)
class ReviewContext:
    """GitHub pull-request review summary details useful for Kanban workers."""

    id: int | None
    author: str | None
    url: str
    body: str
    state: str
    submitted_at: str


@dataclass(frozen=True)
class TrackerItem:
    """Normalized GitHub issue/PR data for Hermes Kanban."""

    kind: str
    number: int
    title: str
    url: str
    labels: tuple[str, ...]
    action: str
    event: str
    delivery_id: str
    comment: CommentContext | None = None
    review: ReviewContext | None = None
    head_ref: str = ""
    base_ref: str = ""

    @property
    def state_label(self) -> str | None:
        for label in self.labels:
            if label in ALL_HERMES_LABELS:
                return label
        return None

    @property
    def idempotency_key(self) -> str:
        state = (self.state_label or "none").removeprefix("hermes:")
        return f"myven:{self.kind}:{self.number}:{state}"


def env_bool(name: str, default: bool) -> bool:
    """Parse a boolean environment variable."""

    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def has_symphony_label(labels: tuple[str, ...]) -> bool:
    """Return True when a GitHub item still carries Symphony-owned state."""

    return any(label.startswith(SYMPHONY_LABEL_PREFIX) for label in labels)


def has_hermes_label(labels: tuple[str, ...]) -> bool:
    """Return True when a GitHub item carries a Hermes Kanban state label."""

    return any(label in ALL_HERMES_LABELS for label in labels)


def allow_mixed_sym_hermes_labels() -> bool:
    """Return True only for explicit one-off migration/debug runs."""

    return env_bool("ALLOW_MIXED_SYM_HERMES_LABELS", False)


def allow_hermes_on_symphony_branches() -> bool:
    """Return True only when an operator explicitly migrates a Symphony branch."""

    return env_bool("ALLOW_HERMES_ON_SYMPHONY_BRANCHES", False)


def is_symphony_branch_ref(ref: str) -> bool:
    """Return True for Symphony-created GitHub branch names."""

    return ref.strip().lower().startswith(SYMPHONY_BRANCH_PREFIX)


def ref_name(endpoint: Any) -> str:
    """Extract a branch ref from a GitHub pull_request head/base endpoint."""

    if isinstance(endpoint, dict) and isinstance(endpoint.get("ref"), str):
        return endpoint["ref"].strip()
    return ""


def should_ignore_item_for_namespace(item: dict[str, Any], labels: tuple[str, ...], kind: str) -> bool:
    """Protect Symphony-owned work from accidental Hermes Kanban ingestion."""

    if not has_hermes_label(labels):
        return True

    if has_symphony_label(labels) and not allow_mixed_sym_hermes_labels():
        LOGGER.warning("ignoring GitHub item with mixed sym/hermes labels: labels=%s", ",".join(labels))
        return True

    head_ref = ref_name(item.get("head"))
    if kind == "pr" and is_symphony_branch_ref(head_ref) and not allow_hermes_on_symphony_branches():
        LOGGER.warning(
            "ignoring Hermes-labeled Symphony branch PR: head_ref=%s labels=%s",
            head_ref,
            ",".join(labels),
        )
        return True

    return False


def labels_from_item(item: dict[str, Any]) -> tuple[str, ...]:
    """Extract lower-case label names from a GitHub issue or PR payload item."""

    labels = item.get("labels") or []
    names: list[str] = []
    for label in labels:
        if isinstance(label, dict) and isinstance(label.get("name"), str):
            names.append(label["name"].strip().lower())
    return tuple(names)


def nested_login(value: Any) -> str:
    """Extract a GitHub login from a nested user/sender object."""

    if isinstance(value, dict) and isinstance(value.get("login"), str):
        return value["login"]
    return ""


def optional_int(value: Any) -> int | None:
    """Return an integer value only when GitHub supplied one."""

    return value if isinstance(value, int) else None


def extract_comment_context(payload: dict[str, Any]) -> CommentContext | None:
    """Extract GitHub issue/comment or PR review comment context when present."""

    comment = payload.get("comment")
    if not isinstance(comment, dict):
        return None

    return CommentContext(
        id=optional_int(comment.get("id")),
        author=nested_login(comment.get("user")) or nested_login(payload.get("sender")),
        url=str(comment.get("html_url") or ""),
        body=str(comment.get("body") or ""),
        path=str(comment.get("path") or ""),
        line=optional_int(comment.get("line")),
        original_line=optional_int(comment.get("original_line")),
        diff_hunk=str(comment.get("diff_hunk") or ""),
    )


def extract_review_context(payload: dict[str, Any]) -> ReviewContext | None:
    """Extract GitHub PR review summary context when present."""

    review = payload.get("review")
    if not isinstance(review, dict):
        return None

    return ReviewContext(
        id=optional_int(review.get("id")),
        author=nested_login(review.get("user")) or nested_login(payload.get("sender")),
        url=str(review.get("html_url") or ""),
        body=str(review.get("body") or ""),
        state=str(review.get("state") or ""),
        submitted_at=str(review.get("submitted_at") or ""),
    )


def extract_tracker_item(envelope: dict[str, Any]) -> TrackerItem | None:
    """Return a Myven issue/PR item when the event is relevant to Hermes."""

    payload = envelope.get("payload") or {}
    repository = payload.get("repository") or {}
    if repository.get("full_name") != os.getenv("GITHUB_REPOSITORY", "studiojin-dev/myven"):
        return None

    event = envelope.get("event") or ""
    action = payload.get("action") or ""
    delivery_id = envelope.get("delivery_id") or ""

    item: dict[str, Any] | None = None
    kind = "issue"

    if "pull_request" in payload:
        item = payload.get("pull_request")
        kind = "pr"
    elif "issue" in payload:
        issue = payload.get("issue")
        if issue and "pull_request" in issue:
            kind = "pr"
        item = issue

    if not isinstance(item, dict):
        return None

    labels = labels_from_item(item)
    if should_ignore_item_for_namespace(item, labels, kind):
        return None

    number = item.get("number")
    if not isinstance(number, int):
        return None

    return TrackerItem(
        kind=kind,
        number=number,
        title=str(item.get("title") or "(untitled)"),
        url=str(item.get("html_url") or ""),
        labels=labels,
        action=str(action),
        event=str(event),
        delivery_id=str(delivery_id),
        comment=extract_comment_context(payload),
        review=extract_review_context(payload),
        head_ref=ref_name(item.get("head")),
        base_ref=ref_name(item.get("base")),
    )


def kanban_status_for_item(item: TrackerItem) -> tuple[str, str]:
    """Map a Hermes-labeled item to assignee and initial Kanban status."""

    match item.state_label:
        case "hermes:todo":
            return "researcher", "ready"
        case "hermes:planned":
            return ("coder", "ready") if item.kind == "pr" else ("operator", "ready")
        case "hermes:review" | "hermes:reviewing":
            return "reviewer", "ready"
        case "hermes:rework":
            return "coder", "ready"
        case "hermes:waiting" | "hermes:human-review":
            return "operator", "blocked"
        case "hermes:merging":
            return "operator", "ready"
        case "hermes:done" | "hermes:canceled" | "hermes:duplicate":
            return "operator", "blocked"
        case _:
            return "operator", "blocked"


def build_task_body(item: TrackerItem) -> str:
    """Build a compact Kanban task body."""

    lines = [
        "Source: Hermes GitHub webhook relay",
        f"GitHub item: {item.kind} #{item.number}",
        f"URL: {item.url}",
        f"Event: {item.event}/{item.action}",
        f"Delivery: {item.delivery_id}",
        f"Labels: {', '.join(item.labels)}",
        f"Idempotency key: {item.idempotency_key}",
    ]

    if item.review is not None:
        lines.extend(review_context_lines(item.review))

    if item.comment is not None:
        lines.extend(comment_context_lines(item.comment))

    lines.extend(
        [
            "",
            "Rules:",
            "- Process only hermes:* labels; ignore sym:* labels.",
            "- Preserve Korean GitHub comments.",
            "- Use worktree workspaces for code-changing work.",
            "- Do not promote hermes:todo or hermes:human-review without human approval.",
        ]
    )

    return "\n".join(lines)


def comment_context_lines(comment: CommentContext) -> list[str]:
    """Render optional GitHub comment details for a Kanban task body."""

    lines = ["", "Comment context:"]
    if comment.id is not None:
        lines.append(f"Comment ID: {comment.id}")
    if comment.url:
        lines.append(f"Comment URL: {comment.url}")
    if comment.author:
        lines.append(f"Comment author: {comment.author}")
    if comment.path:
        lines.append(f"Comment path: {comment.path}")
    if comment.line is not None:
        lines.append(f"Comment line: {comment.line}")
    if comment.original_line is not None:
        lines.append(f"Comment original line: {comment.original_line}")
    if comment.body:
        lines.extend(["Comment body:", comment.body])
    if comment.diff_hunk:
        lines.extend(["Diff hunk:", comment.diff_hunk])
    return lines


def review_context_lines(review: ReviewContext) -> list[str]:
    """Render optional GitHub review summary details for a Kanban task body."""

    lines = ["", "Review context:"]
    if review.id is not None:
        lines.append(f"Review ID: {review.id}")
    if review.url:
        lines.append(f"Review URL: {review.url}")
    if review.author:
        lines.append(f"Review author: {review.author}")
    if review.state:
        lines.append(f"Review state: {review.state}")
    if review.submitted_at:
        lines.append(f"Review submitted at: {review.submitted_at}")
    if review.body:
        lines.extend(["Review body:", review.body])
    return lines


def run_command(command: list[str], cwd: str, dry_run: bool) -> subprocess.CompletedProcess[str] | None:
    """Run or log a command."""

    rendered = " ".join(shlex.quote(part) for part in command)
    if dry_run:
        LOGGER.info("dry-run command cwd=%s: %s", cwd, rendered)
        return None

    LOGGER.info("running command cwd=%s: %s", cwd, rendered)
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=True)


def hermes_board() -> str:
    """Return the target Hermes board slug for Myven."""

    return os.getenv("HERMES_KANBAN_BOARD", "myven")


def github_repo() -> str:
    """Return the GitHub repository used by the relay."""

    return os.getenv("GITHUB_REPOSITORY", "studiojin-dev/myven")


def github_binary() -> str:
    """Return the GitHub CLI executable path."""

    configured = os.getenv("GH_BIN")
    if configured:
        return configured
    return shutil.which("gh") or "gh"


def review_bot_logins() -> set[str]:
    """Return the GitHub logins treated as Codex review actors."""

    raw = os.getenv(
        "CODEX_REVIEW_BOT_LOGINS",
        "chatgpt-codex-connector,chatgpt-codex-connector[bot],codex,codex[bot]",
    )
    return {login.strip().lower() for login in raw.split(",") if login.strip()}


def is_codex_review_author(login: str | None) -> bool:
    """Return True when the login looks like the Codex review bot."""

    return bool(login) and login.lower() in review_bot_logins()


def telegram_home_subscription() -> tuple[str, str | None] | None:
    """Return the Telegram home channel used for task subscriptions."""

    chat_id = os.getenv("TELEGRAM_HOME_CHANNEL")
    if not chat_id:
        return None
    thread_id = os.getenv("TELEGRAM_HOME_CHANNEL_THREAD_ID") or None
    return chat_id, thread_id


def subscribe_task_for_telegram(task_id: str, workdir: str, dry_run: bool) -> None:
    """Subscribe a Kanban task to the Telegram home channel, if configured."""

    destination = telegram_home_subscription()
    if destination is None:
        LOGGER.warning(
            "skipping auto notify-subscribe for %s: TELEGRAM_HOME_CHANNEL is unset",
            task_id,
        )
        return

    chat_id, thread_id = destination
    command = [
        hermes_binary(),
        "kanban",
        "--board",
        hermes_board(),
        "notify-subscribe",
        task_id,
        "--platform",
        "telegram",
        "--chat-id",
        chat_id,
    ]
    if thread_id:
        command.extend(["--thread-id", thread_id])

    run_command(command, cwd=workdir, dry_run=dry_run)


def human_review_comment_body(item: TrackerItem, task_id: str) -> str:
    """Build the GitHub comment that makes a blocked item visible to humans."""

    return "\n".join(
        [
            "Hermes Kanban에서 이 GitHub 항목을 human review 필요 상태로 표시했습니다.",
            "",
            f"- GitHub item: {item.kind} #{item.number}",
            f"- Kanban task: {task_id}",
            f"- Delivery: {item.delivery_id}",
            f"- Event: {item.event}/{item.action}",
            f"- Current label: {item.state_label or 'none'}",
            "",
            f"GitHub 라벨을 `{HUMAN_REVIEW_LABEL}`로 맞췄습니다. 사람이 확인해 주세요.",
        ]
    )


def github_human_review_comment_exists(item: TrackerItem, workdir: str, dry_run: bool) -> bool:
    """Return True when a matching human-review marker comment already exists."""

    if dry_run:
        return False

    result = run_command(
        [
            github_binary(),
            "api",
            f"repos/{github_repo()}/issues/{item.number}/comments?per_page=100",
        ],
        cwd=workdir,
        dry_run=False,
    )
    if result is None or not result.stdout.strip():
        return False

    try:
        comments = json.loads(result.stdout)
    except json.JSONDecodeError:
        LOGGER.warning("failed to parse GitHub comments for %s #%s", item.kind, item.number)
        return False

    if not isinstance(comments, list):
        return False

    marker = f"- Delivery: {item.delivery_id}"
    return any(
        isinstance(comment, dict) and marker in str(comment.get("body") or "")
        for comment in comments
    )


def sync_github_human_review(item: TrackerItem, task_id: str, workdir: str, dry_run: bool) -> None:
    """Make a blocked item visible on GitHub by syncing label and comment."""

    labels_to_remove = [
        label for label in item.labels if label in ALL_HERMES_LABELS and label != HUMAN_REVIEW_LABEL
    ]

    edit_command = [
        github_binary(),
        "issue",
        "edit",
        str(item.number),
        "--repo",
        github_repo(),
    ]
    for label in labels_to_remove:
        edit_command.extend(["--remove-label", label])
    edit_command.extend(["--add-label", HUMAN_REVIEW_LABEL])
    run_command(edit_command, cwd=workdir, dry_run=dry_run)

    if github_human_review_comment_exists(item, workdir=workdir, dry_run=dry_run):
        LOGGER.info(
            "skipping duplicate human-review comment for %s #%s delivery=%s",
            item.kind,
            item.number,
            item.delivery_id,
        )
        return

    run_command(
        [
            github_binary(),
            "issue",
            "comment",
            str(item.number),
            "--repo",
            github_repo(),
            "--body",
            human_review_comment_body(item, task_id),
        ],
        cwd=workdir,
        dry_run=dry_run,
    )


def sync_github_review(item: TrackerItem, task_id: str, workdir: str, dry_run: bool) -> None:
    """Make a rework-complete item visible on GitHub by syncing the review label and comment."""

    labels_to_remove = [
        label for label in item.labels if label in ALL_HERMES_LABELS and label != REVIEW_LABEL
    ]

    edit_command = [
        github_binary(),
        "issue",
        "edit",
        str(item.number),
        "--repo",
        github_repo(),
    ]
    for label in labels_to_remove:
        edit_command.extend(["--remove-label", label])
    edit_command.extend(["--add-label", REVIEW_LABEL])
    run_command(edit_command, cwd=workdir, dry_run=dry_run)

    if github_human_review_comment_exists(item, workdir=workdir, dry_run=dry_run):
        LOGGER.info(
            "skipping duplicate review comment for %s #%s delivery=%s",
            item.kind,
            item.number,
            item.delivery_id,
        )
        return

    run_command(
        [
            github_binary(),
            "issue",
            "comment",
            str(item.number),
            "--repo",
            github_repo(),
            "--body",
            review_comment_body(item, task_id),
        ],
        cwd=workdir,
        dry_run=dry_run,
    )


REWORK_LABEL = "hermes:rework"


def review_comment_body(item: TrackerItem, task_id: str) -> str:
    """Build the GitHub comment that moves a fixed PR back to review."""

    return "\n".join(
        [
            "Rework가 완료되어 이 GitHub 항목을 다시 review 상태로 되돌렸습니다.",
            "",
            f"- GitHub item: {item.kind} #{item.number}",
            f"- Kanban task: {task_id}",
            f"- Delivery: {item.delivery_id}",
            f"- Event: {item.event}/{item.action}",
            f"- Current label: {item.state_label or 'none'}",
            "",
            f"GitHub 라벨을 `{REVIEW_LABEL}`로 맞췄습니다. 다시 Codex review를 돌려 주세요.",
        ]
    )


def rework_comment_body(item: TrackerItem, task_id: str) -> str:
    """Build the GitHub comment that makes a review request visible to humans."""

    return "\n".join(
        [
            "Codex review에서 수정 요청이 확인되어 이 GitHub 항목을 rework 상태로 되돌렸습니다.",
            "",
            f"- GitHub item: {item.kind} #{item.number}",
            f"- Kanban task: {task_id}",
            f"- Delivery: {item.delivery_id}",
            f"- Event: {item.event}/{item.action}",
            f"- Current label: {item.state_label or 'none'}",
            "",
            f"GitHub 라벨을 `{REWORK_LABEL}`로 맞췄습니다. 수정 후 Codex review를 다시 돌려 주세요.",
        ]
    )


def sync_github_rework(item: TrackerItem, task_id: str, workdir: str, dry_run: bool) -> None:
    """Make review feedback visible on GitHub by syncing the rework label and comment."""

    labels_to_remove = [
        label for label in item.labels if label in ALL_HERMES_LABELS and label != REWORK_LABEL
    ]

    edit_command = [
        github_binary(),
        "issue",
        "edit",
        str(item.number),
        "--repo",
        github_repo(),
    ]
    for label in labels_to_remove:
        edit_command.extend(["--remove-label", label])
    edit_command.extend(["--add-label", REWORK_LABEL])
    run_command(edit_command, cwd=workdir, dry_run=dry_run)

    if github_human_review_comment_exists(item, workdir=workdir, dry_run=dry_run):
        LOGGER.info(
            "skipping duplicate rework comment for %s #%s delivery=%s",
            item.kind,
            item.number,
            item.delivery_id,
        )
        return

    run_command(
        [
            github_binary(),
            "issue",
            "comment",
            str(item.number),
            "--repo",
            github_repo(),
            "--body",
            rework_comment_body(item, task_id),
        ],
        cwd=workdir,
        dry_run=dry_run,
    )


def hermes_binary() -> str:
    """Return a launchd-safe Hermes executable path."""

    configured = os.getenv("HERMES_BIN")
    if configured:
        return configured
    user_local = os.path.expanduser("~/.local/bin/hermes")
    if os.path.exists(user_local):
        return user_local
    return shutil.which("hermes") or "hermes"


def created_task_id(result: subprocess.CompletedProcess[str] | None) -> str | None:
    """Extract the task id from `hermes kanban create --json` output."""

    if result is None or not result.stdout:
        return None
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    if isinstance(payload, dict):
        for key in ("id", "task_id"):
            value = payload.get(key)
            if isinstance(value, str) and value:
                return value
    return None


def review_transition_for_item(item: TrackerItem) -> str | None:
    """Return the GitHub label transition implied by a Codex review event."""

    if item.kind != "pr" or not item.event.startswith("pull_request_review"):
        return None

    review_state = (item.review.state if item.review is not None else "").strip().upper()
    review_author = item.review.author if item.review is not None else None
    comment_author = item.comment.author if item.comment is not None else None

    if review_state == "CHANGES_REQUESTED":
        return REWORK_LABEL
    if item.comment is not None and is_codex_review_author(comment_author):
        return REWORK_LABEL
    if item.review is not None and is_codex_review_author(review_author):
        if review_state in {"APPROVED", "COMMENTED"}:
            if item.state_label == REWORK_LABEL:
                return REVIEW_LABEL
            return HUMAN_REVIEW_LABEL
    return None


def live_pr_head_ref(item: TrackerItem, workdir: str, dry_run: bool) -> str:
    """Fetch the live PR head branch when webhook payloads omit it."""

    if dry_run:
        return ""

    result = run_command(
        [
            github_binary(),
            "pr",
            "view",
            str(item.number),
            "--repo",
            github_repo(),
            "--json",
            "headRefName",
            "--jq",
            ".headRefName",
        ],
        cwd=workdir,
        dry_run=False,
    )
    if result is None:
        return ""
    return result.stdout.strip()


def should_skip_reconcile_for_namespace(item: TrackerItem, workdir: str, dry_run: bool) -> bool:
    """Protect PR comment events whose payload lacks a head ref from Symphony branch leaks."""

    if item.kind != "pr" or item.head_ref or item.event != "issue_comment":
        return False
    if allow_hermes_on_symphony_branches():
        return False

    head_ref = live_pr_head_ref(item, workdir=workdir, dry_run=dry_run)
    if is_symphony_branch_ref(head_ref):
        LOGGER.warning(
            "ignoring Hermes-labeled issue_comment for live Symphony branch PR: pr=%s head_ref=%s labels=%s",
            item.number,
            head_ref,
            ",".join(item.labels),
        )
        return True
    return False


def reconcile_item(item: TrackerItem, dry_run: bool) -> None:
    """Create or reuse a Kanban task for the GitHub item.

    `--idempotency-key` prevents duplicate non-archived cards for repeated
    GitHub deliveries and JetStream redelivery.
    """

    review_transition = review_transition_for_item(item)
    task_item = replace(item, labels=(review_transition,) if review_transition else item.labels)
    assignee, status = kanban_status_for_item(task_item)
    workdir = os.getenv("MYVEN_WORKDIR", "/Users/kimjeongjin/Repo/active/myven")
    if should_skip_reconcile_for_namespace(item, workdir=workdir, dry_run=dry_run):
        return
    title = f"{task_item.state_label or 'hermes'} {task_item.kind} #{task_item.number}: {task_item.title}"
    body = build_task_body(task_item)

    command = [
        hermes_binary(),
        "kanban",
        "--board",
        hermes_board(),
        "create",
        title,
        "--assignee",
        assignee,
        "--idempotency-key",
        task_item.idempotency_key,
        "--created-by",
        "myven-hermes-webhook-consumer",
        "--body",
        body,
        "--json",
    ]

    if status == "blocked":
        body += "\nInitial state: blocked/human gate or terminal relay notice."
        command[command.index("--body") + 1] = body
        command.extend(["--initial-status", "blocked"])

    result = run_command(command, cwd=workdir, dry_run=dry_run)
    task_id = created_task_id(result)
    if task_id and item.comment is not None:
        comment_body = "\n".join(
            [
                "GitHub webhook comment/review context appended to the idempotent task.",
                *comment_context_lines(item.comment),
            ]
        )
        run_command(
            [
                hermes_binary(),
                "kanban",
                "--board",
                hermes_board(),
                "comment",
                task_id,
                comment_body,
            ],
            cwd=workdir,
            dry_run=dry_run,
        )

    if task_id is not None:
        try:
            subscribe_task_for_telegram(task_id, workdir=workdir, dry_run=dry_run)
        except Exception:
            LOGGER.exception("failed to auto-subscribe task %s", task_id)

    review_transition = review_transition_for_item(item)
    if task_id is not None and review_transition == REWORK_LABEL:
        sync_github_rework(item, task_id=task_id, workdir=workdir, dry_run=dry_run)
    elif task_id is not None and review_transition == REVIEW_LABEL:
        sync_github_review(item, task_id=task_id, workdir=workdir, dry_run=dry_run)
    elif task_id is not None and review_transition == HUMAN_REVIEW_LABEL:
        sync_github_human_review(item, task_id=task_id, workdir=workdir, dry_run=dry_run)

    if task_id is not None and status == "blocked":
        sync_github_human_review(item, task_id=task_id, workdir=workdir, dry_run=dry_run)


def decode_message(data: bytes) -> dict[str, Any]:
    """Decode a JetStream message body."""

    return json.loads(data.decode("utf-8"))


async def consume_forever() -> None:
    """Subscribe to JetStream and process webhook deliveries forever."""

    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
    dry_run = env_bool("DRY_RUN", True)
    nats_url = os.getenv("NATS_URL", "nats://127.0.0.1:4222")
    token = os.getenv("NATS_AUTH_TOKEN")
    stream = os.getenv("NATS_STREAM", "GITHUB_WEBHOOKS")
    subject = os.getenv("NATS_SUBJECT", "github.webhook.*")
    durable = os.getenv("NATS_DURABLE", "myven-hermes-kanban")

    options: dict[str, Any] = {
        "servers": [nats_url],
        "name": "myven-hermes-kanban-consumer",
        "connect_timeout": 10,
        "max_reconnect_attempts": -1,
    }
    if token:
        options["token"] = token

    nc = NATS()
    await nc.connect(**options)
    js = nc.jetstream()
    subscription = await js.pull_subscribe(subject, durable=durable, stream=stream)

    LOGGER.info("consumer started stream=%s subject=%s durable=%s dry_run=%s", stream, subject, durable, dry_run)

    try:
        while True:
            try:
                messages = await subscription.fetch(batch=10, timeout=5)
            except JETSTREAM_TIMEOUT_ERRORS:
                continue

            for message in messages:
                try:
                    envelope = decode_message(message.data)
                    item = extract_tracker_item(envelope)
                    if item is None:
                        await message.ack()
                        continue

                    LOGGER.info(
                        "reconciling %s #%s label=%s delivery=%s",
                        item.kind,
                        item.number,
                        item.state_label,
                        item.delivery_id,
                    )
                    reconcile_item(item, dry_run=dry_run)
                    await message.ack()
                except Exception:
                    LOGGER.exception("failed to process message; nak for redelivery")
                    await message.nak()
    finally:
        await nc.drain()


def main() -> None:
    """Run the consumer."""

    asyncio.run(consume_forever())


if __name__ == "__main__":
    main()
