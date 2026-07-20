---
tracker:
  kind: forgejo
  endpoint: https://forgejo.example.org/api/v1
  owner: example
  repo: project
  read_api_key: $SYMPHONY_TRACKER_READ_TOKEN
  write_api_key: $SYMPHONY_TRACKER_WRITE_TOKEN
  bot_login: symphony
  active_states:
    - Todo
    - Planned
    - In Progress
    - Review
    - Reviewing
    - Rework
    - Reworking
    - Merging
state_manager:
  mode: authoritative
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
  source: $SOURCE_REPO_PATH
  base_ref: origin/main
hooks:
  after_create: |
    git clone "$SOURCE_REPO_URL" .
agent:
  dispatch_kinds:
    - issue
    - pull_request
codex:
  command: codex app-server
---

You are working on Forgejo tracker item `{{ issue.identifier }}`.

Title: {{ issue.title }}

Body:
{{ issue.description }}

Return a structured semantic outcome. Symphony owns tracker labels, automated comments, pull-request
creation, and merging. Do not use a tracker CLI or expose tracker credentials from the worker.
