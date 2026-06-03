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
