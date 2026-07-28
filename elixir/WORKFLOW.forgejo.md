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
creation, merging, and inline-review closeout. For Rework, report every supplied unresolved inline
thread through `review_thread_updates`; do not use a tracker CLI or expose tracker credentials from
the worker. If the configured Forgejo instance cannot prove an inline reply-and-resolve API,
Symphony will hand off instead of silently closing the review loop.
