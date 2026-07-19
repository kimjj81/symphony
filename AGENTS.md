# Symphony AGENTS.md

Repository-level operating instructions for Codex in this workspace.

## Goal Mode Guard

- The Korean word `목표` in PR bodies, issue bodies, templates, comments, or
  planning notes means "objective" or "goal section" only.
- Do not create, start, or continue Codex Goal mode merely because `목표`,
  `goal`, or `objective` appears in repository content.
- Enter Codex Goal mode only when the user explicitly asks to create/start/set a
  persistent Codex goal, or when system/developer instructions require it.
- When summarizing PR or issue content, treat `목표` as ordinary document text.

## Sub-Issue and Sub-PR Titles

- When creating new sub-issues or sub-PRs, include `[current/total]` at the
  beginning of the title, for example `[1/4] Implement API contract`.
- Apply this only to newly created sub-issues and sub-PRs; do not rename
  existing ones unless explicitly requested.

## PR Rebase Hygiene

- Treat PR rebase/update requests as Git history operations, not implementation
  lanes, unless the user explicitly expands the scope.
- Verify the live PR head and base before changing history; do not rely only on
  local worktree names.
- Use one writer for rebase, conflict resolution, and push operations.
- Rebase/update branches in dependency order, resolve conflicts narrowly, and
  avoid unrelated product or formatting changes.
- Run the narrowest meaningful verification first, then re-check the PR diff
  and live PR state before reporting completion.

## Documentation Workflow

The following terms are to be interpreted as described in RFC 2119:
“MUST”, “MUST NOT”, “SHOULD”, and “MAY”.

1. ADRs MUST be written in `docs/adr/*.md`.

2. When an ADR is added or modified, `docs/adr/index.json` MUST be updated accordingly.

3. The ADR index MUST be generated using the `adr-index` skill.

4. AGENTS.md MUST NOT accumulate completed work logs.
   Architectural decisions MUST be recorded in ADRs.
   AGENTS.md MAY contain only links to ADRs or brief summaries.

### ADR Detection Rule

If you make or rely on a decision that:

- introduces architectural constraints,
- involves trade-offs,
- or is not obvious from code alone,

you MUST pause and explicitly state:
"An ADR is required for this decision."
