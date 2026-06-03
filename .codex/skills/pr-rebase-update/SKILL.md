---
name: pr-rebase-update
description: Update GitHub PR branches by rebasing or merging them onto the latest required base. Use when Codex is asked to rebase a PR, update a PR with latest main, refresh a PR against its base, update a parent branch before a child PR, fix a PR after its base moved, resolve PR rebase conflicts, or sync ordinary or stacked/dependent PR branches.
---

# PR Rebase Update

## Operating Rule

Treat PR update/rebase requests as Git history operations, not implementation
lanes. Do not reopen product scope unless the user explicitly asks.

Use exactly one writer for rebase, conflict resolution, and push. Read-only
investigation may be delegated, but Git history mutation stays with the
conductor.

## Workflow

### 1. Preflight

- Identify the repo and current worktree.
- Run `git status --short`.
- Verify live PR state before changing history:

```bash
gh pr view <PR> --json number,headRefName,baseRefName,headRepositoryOwner,baseRepositoryOwner,isCrossRepository,state,mergeStateStatus
```

- Do not trust local worktree names as branch truth.
- Decide whether the PR is ordinary or stacked/dependent.
- If local changes exist, determine whether they are related. Do not overwrite
  unrelated changes.

### 2. Fetch

- Fetch `origin main`.
- Fetch the PR head branch.
- Fetch the PR base branch.
- For stacked PRs, fetch all known parent/dependency branches in order.

### 3. Choose Update Strategy

- If the user explicitly requested rebase, use rebase.
- If repo policy requires merge, or the PR is from a fork where push is
  unavailable, stop with `QUESTION`.
- For ordinary PRs, update the PR head onto the latest base.
- For stacked PRs, update parent/dependency branches first, then child PR
  branches in dependency order.

### 4. Rebase and Conflicts

- Rebase one branch at a time.
- Resolve conflicts narrowly.
- Do not make unrelated formatting, product, dependency, schema, auth, CI/CD, or
  release changes.
- If conflict resolution requires a product decision, stop with `QUESTION`.
- If an editor blocks `git rebase --continue`, continue non-interactively:

```bash
GIT_EDITOR=true git rebase --continue
```

### 5. Verification

- Run the narrowest meaningful test or build command first.
- If no test is appropriate, run at least a diff/status sanity check.
- For code conflicts, inspect resolved files and run focused tests around the
  touched area.
- Do not claim completion without command evidence or observable PR state.

### 6. Push and Final Check

- Push rewritten branches with `git push --force-with-lease`, never plain force.
- Re-query `gh pr view`.
- Check the PR diff against the intended base.
- Check relevant CI/check state when available.
- Confirm labels/comments only if the workflow or user request requires tracker
  synchronization.

## Failure Handling

- If the live PR head differs from the local branch, fetch or switch to the live
  head before proceeding.
- If push is rejected, fetch again and inspect whether the remote branch
  advanced.
- If rebase state is broken or another rebase is already in progress, inspect
  `git status` before continuing or aborting.
- Do not use destructive commands such as hard reset, branch deletion, or rebase
  abort unless clearly needed and allowed by user/developer instructions.
- If verification cannot be run, report exactly why and what was checked
  instead.

## Completion Report

Use explicit status `COMPLETE`, `QUESTION`, or `ERROR`.

For `COMPLETE`, include:

- Summary of branch update
- Whether PR was ordinary or stacked
- Branches updated
- Files changed by conflict resolution, if any
- Commands executed
- Verification results
- Live PR state checked
- Remaining risks or follow-ups

For `QUESTION` or `ERROR`, include:

- What is blocked
- What was checked
- Smallest next decision needed
