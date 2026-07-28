# Shared local NATS tunnel

This launchd template exposes the private NATS service to a local Symphony
process. It is shared transport infrastructure and must remain running when
`SYMPHONY_NATS_URL` points to `nats://100.77.171.83:24222`.

Install it outside git, replace environment-specific host values if needed,
and validate the copied plist before bootstrapping it:

```bash
mkdir -p ~/Library/LaunchAgents
cp com.studiojin.myven-nats-tunnel.plist.example \
  ~/Library/LaunchAgents/com.studiojin.myven-nats-tunnel.plist
plutil -lint ~/Library/LaunchAgents/com.studiojin.myven-nats-tunnel.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.studiojin.myven-nats-tunnel.plist
```
