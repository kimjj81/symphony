"""GitHub webhook relay entrypoint.

This service is deliberately workflow-agnostic. It verifies GitHub delivery
signatures, wraps the delivery, and publishes it to NATS JetStream. Consumers
(Symphony, Hermes Kanban, etc.) decide what labels/events they care about.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import os
import signal
from datetime import UTC, datetime
from typing import Any

from aiohttp import web
from nats.aio.client import Client as NATS
from nats.js.api import StreamConfig
from nats.js.errors import NotFoundError

LOGGER = logging.getLogger("github_webhook_relay")

DEFAULT_STREAM = "GITHUB_WEBHOOKS"
DEFAULT_SUBJECT_PREFIX = "github.webhook"


class RelayState:
    """Mutable process state shared by aiohttp handlers."""

    def __init__(self) -> None:
        self.nats = NATS()
        self.jetstream: Any | None = None
        self.stream = os.getenv("NATS_STREAM", DEFAULT_STREAM)
        self.subject_prefix = os.getenv("NATS_SUBJECT_PREFIX", DEFAULT_SUBJECT_PREFIX)
        self.github_secret = os.getenv("GITHUB_WEBHOOK_SECRET", "")


STATE = RelayState()


def build_subject(prefix: str, event_name: str | None) -> str:
    """Return a conservative NATS subject for a GitHub event name."""

    normalized = (event_name or "unknown").strip().lower().replace("_", "-")
    safe = "".join(ch for ch in normalized if ch.isalnum() or ch == "-") or "unknown"
    return f"{prefix}.{safe}"


def verify_github_signature(secret: str, body: bytes, signature_header: str | None) -> bool:
    """Verify GitHub's X-Hub-Signature-256 header.

    If no secret is configured, verification is disabled for local smoke tests.
    Do not run the public service without a secret.
    """

    if not secret:
        return True

    if not signature_header or not signature_header.startswith("sha256="):
        return False

    expected = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    supplied = signature_header.removeprefix("sha256=")
    return hmac.compare_digest(expected, supplied)


def build_envelope(headers: dict[str, str], payload: Any) -> dict[str, Any]:
    """Build the event envelope published to JetStream."""

    return {
        "delivery_id": headers.get("x-github-delivery", ""),
        "event": headers.get("x-github-event", ""),
        "received_at": datetime.now(UTC).isoformat(),
        "headers": {
            "x-github-delivery": headers.get("x-github-delivery", ""),
            "x-github-event": headers.get("x-github-event", ""),
            "x-github-hook-id": headers.get("x-github-hook-id", ""),
        },
        "payload": payload,
    }


async def ensure_stream() -> None:
    """Create the JetStream stream if it does not already exist."""

    if STATE.jetstream is None:
        raise RuntimeError("JetStream is not initialized")

    subjects = [f"{STATE.subject_prefix}.*"]

    try:
        await STATE.jetstream.stream_info(STATE.stream)
    except NotFoundError:
        await STATE.jetstream.add_stream(
            StreamConfig(
                name=STATE.stream,
                subjects=subjects,
                storage="file",
                max_age=int(os.getenv("NATS_MAX_AGE_SECONDS", "1209600")),
                duplicate_window=int(os.getenv("NATS_DUPLICATE_WINDOW_SECONDS", "86400")),
            )
        )


async def connect_nats(app: web.Application) -> None:
    """Connect to NATS on application startup."""

    del app
    nats_url = os.getenv("NATS_URL", "nats://nats:4222")
    token = os.getenv("NATS_AUTH_TOKEN")
    options: dict[str, Any] = {
        "servers": [nats_url],
        "name": "github-webhook-relay",
        "connect_timeout": 5,
        "max_reconnect_attempts": -1,
    }
    if token:
        options["token"] = token

    await STATE.nats.connect(**options)
    STATE.jetstream = STATE.nats.jetstream()
    await ensure_stream()
    LOGGER.info("connected to NATS stream=%s prefix=%s", STATE.stream, STATE.subject_prefix)


async def disconnect_nats(app: web.Application) -> None:
    """Drain NATS connection on shutdown."""

    del app
    if STATE.nats.is_connected:
        await STATE.nats.drain()


async def health(_: web.Request) -> web.Response:
    """Return process and NATS health."""

    return web.json_response(
        {
            "status": "ok" if STATE.nats.is_connected else "degraded",
            "nats_connected": STATE.nats.is_connected,
            "stream": STATE.stream,
            "subject_prefix": STATE.subject_prefix,
        },
        status=200 if STATE.nats.is_connected else 503,
    )


async def github_webhook(request: web.Request) -> web.Response:
    """Receive a GitHub webhook delivery and publish it to JetStream."""

    body = await request.read()
    signature = request.headers.get("X-Hub-Signature-256")

    if not verify_github_signature(STATE.github_secret, body, signature):
        return web.json_response({"error": "invalid signature"}, status=401)

    try:
        payload = json.loads(body.decode("utf-8")) if body else {}
    except json.JSONDecodeError:
        return web.json_response({"error": "invalid json"}, status=400)

    headers = {key.lower(): value for key, value in request.headers.items()}
    delivery_id = headers.get("x-github-delivery")
    event_name = headers.get("x-github-event")

    if not delivery_id:
        return web.json_response({"error": "missing X-GitHub-Delivery"}, status=400)

    subject = build_subject(STATE.subject_prefix, event_name)
    envelope = build_envelope(headers, payload)
    message = json.dumps(envelope, separators=(",", ":")).encode("utf-8")

    if STATE.jetstream is None:
        return web.json_response({"error": "jetstream unavailable"}, status=503)

    ack = await STATE.jetstream.publish(
        subject,
        message,
        headers={"Nats-Msg-Id": delivery_id},
    )

    LOGGER.info(
        "published github delivery event=%s delivery_id=%s subject=%s seq=%s",
        event_name,
        delivery_id,
        subject,
        ack.seq,
    )

    return web.json_response(
        {
            "ok": True,
            "delivery_id": delivery_id,
            "event": event_name,
            "stream": ack.stream,
            "seq": ack.seq,
        }
    )


def create_app() -> web.Application:
    """Create the aiohttp application."""

    app = web.Application(client_max_size=int(os.getenv("MAX_BODY_BYTES", "26214400")))
    app.router.add_get("/health", health)
    app.router.add_post("/github", github_webhook)
    app.on_startup.append(connect_nats)
    app.on_cleanup.append(disconnect_nats)
    return app


def main() -> None:
    """Run the relay service."""

    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
    app = create_app()
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, loop.stop)

    web.run_app(
        app,
        host=os.getenv("HOST", "0.0.0.0"),
        port=int(os.getenv("PORT", "8080")),
        loop=loop,
    )


if __name__ == "__main__":
    main()
