# Mac consumer setup

Run from this directory:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
python -m py_compile myven_hermes_consumer.py
```

Copy the plist examples to LaunchAgents and replace placeholder values outside git:

```bash
mkdir -p ~/Library/LaunchAgents
cp com.studiojin.myven-nats-tunnel.plist.example \
  ~/Library/LaunchAgents/com.studiojin.myven-nats-tunnel.plist
cp com.studiojin.myven-hermes-webhook-consumer.plist.example \
  ~/Library/LaunchAgents/com.studiojin.myven-hermes-webhook-consumer.plist
plutil -lint ~/Library/LaunchAgents/com.studiojin.myven-nats-tunnel.plist
plutil -lint ~/Library/LaunchAgents/com.studiojin.myven-hermes-webhook-consumer.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.studiojin.myven-nats-tunnel.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.studiojin.myven-hermes-webhook-consumer.plist
```

On the current Oracle setup, the Mac consumer reaches NATS through an SSH-managed `kubectl port-forward` bound to Oracle's Tailscale IP:

```text
Mac consumer -> nats://100.77.171.83:24222
Oracle ssh command -> kubectl -n webhook-relay port-forward --address 100.77.171.83 svc/nats 24222:4222
```

Keep `DRY_RUN=true` until the NATS event flow is verified. Set `DRY_RUN=false` only after confirming the generated `hermes kanban --board myven create ...` commands are correct.

The consumer includes GitHub comment context in Kanban task bodies when webhook payloads contain `comment`, including `issue_comment` and `pull_request_review_comment` deliveries. Inline review comments include URL, author, body, path, line/original line, and diff hunk when GitHub supplies those fields.

Logs:

```bash
tail -f ~/Library/Logs/myven-hermes-webhook-consumer.log
tail -f ~/Library/Logs/myven-hermes-webhook-consumer.err.log
```
