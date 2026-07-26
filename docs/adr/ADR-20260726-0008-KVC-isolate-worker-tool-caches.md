# ADR-20260726-0008-KVC: Isolate worker tool caches

Tags: orchestration, codex, sandbox, cache, security, reliability
Status: Accepted
Date: 2026-07-26
TL;DR: Symphony gives every Codex app-server worker a temporary writable cache root and removes it with the session.

## Context

Codex workers run with a workspace-write sandbox whose writable roots intentionally exclude the
worker account's home directory. Repository verification commands can still invoke tools such as
uv and Gitleaks that default to `~/.cache`. Those tools then fail before exercising product code,
even though the workspace and the platform-provided temporary directory are writable.

Adding the shared home cache to every worker's writable roots would weaken isolation and allow
concurrent sessions to contend over mutable cache indexes and lock files. Teaching each managed
repository to recognize Symphony would duplicate an orchestration concern across repositories.

## Decision

Symphony assigns each local and SSH Codex app-server process cache paths beneath the process's
existing temporary runtime directory:

- `XDG_CACHE_HOME` for tools that follow the XDG cache convention.
- `UV_CACHE_DIR` for uv's explicit cache contract.
- `MYVEN_GITLEAKS_CACHE_DIR` for Myven's verified Gitleaks installer.

The paths are unique per app-server session, inherit the runtime directory's restrictive
permissions, and remain inside the temporary paths already allowed by the default Codex sandbox
policy. Symphony removes the common runtime directory when the session stops or startup fails.

Repository commands remain responsible for selecting their verification lanes. Symphony only
provides a writable execution cache and does not skip checks, broaden home-directory access, or
reinterpret tool failures as successful verification.

## Consequences

- Verification tools can write cache data without requesting access to the worker's home directory.
- Concurrent workers no longer share uv or Myven Gitleaks cache locks and mutable indexes.
- Local and SSH workers receive the same cache isolation contract.
- A fresh session may download or rebuild artifacts that a shared cache could reuse, increasing
  startup time and network use.
- Additional tools that ignore XDG cache conventions need an explicit worker environment variable
  before they gain the same isolation.
