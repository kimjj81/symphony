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
import subprocess
from dataclasses import dataclass
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


@dataclass(frozen=True)
class CommentContext:
    """GitHub comment/review-comment details useful for Kanban workers."""

    id: int | None
    author: str
    url: str
    body: str
    path: str
    line: int | None
    original_line: int | None
    diff_hunk: str


@dataclass(frozen=True)
class TrackerItem:
    """Minimal GitHub item projection needed for Kanban reconciliation."""

    kind: str
    number: int
    title: str
    url: str
    labels: tuple[str, ...]
    action: str
    event: str
    delivery_id: str
    comment: CommentContext | None = None

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
    if not any(label in ALL_HERMES_LABELS for label in labels):
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


def run_command(command: list[str], cwd: str, dry_run: bool) -> subprocess.CompletedProcess[str] | None:
    """Run or log a command."""

    rendered = " ".join(shlex.quote(part) for part in command)
    if dry_run:
        LOGGER.info("dry-run command cwd=%s: %s", cwd, rendered)
        return None

    LOGGER.info("running command cwd=%s: %s", cwd, rendered)
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=True)


def reconcile_item(item: TrackerItem, dry_run: bool) -> None:
    """Create or reuse a Kanban task for the GitHub item.

    `--idempotency-key` prevents duplicate non-archived cards for repeated
    GitHub deliveries and JetStream redelivery.
    """

    assignee, status = kanban_status_for_item(item)
    workdir = os.getenv("MYVEN_WORKDIR", "/Users/kimjeongjin/Repo/active/myven")
    title = f"{item.state_label or 'hermes'} {item.kind} #{item.number}: {item.title}"
    body = build_task_body(item)

    command = [
        "hermes",
        "kanban",
        "--board",
        os.getenv("HERMES_KANBAN_BOARD", "myven"),
        "create",
        title,
        "--assignee",
        assignee,
        "--idempotency-key",
        item.idempotency_key,
        "--created-by",
        "myven-hermes-webhook-consumer",
        "--body",
        body,
    ]

    if status == "blocked":
        body += "\nInitial state: blocked/human gate or terminal relay notice."
        command[-1] = body
        command.extend(["--initial-status", "blocked"])

    run_command(command, cwd=workdir, dry_run=dry_run)


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
