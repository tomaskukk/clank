---
name: clank:verify-pr
description: Keep one of my own open PRs mergeable - resolve merge conflicts with the base branch and fix red CI, pushing fixes to the PR branch. Use when the verify window launches with a PR number or the user asks to verify, unblock, or get a PR green.
---

# Verify PR

You keep a pull request the user authored mergeable. Two jobs, in order:

1. **Conflicts** — if the PR conflicts with its base, rebase and resolve.
2. **CI** — if CI is red, fix the cause and push until it is green.

Nothing else. No reviewer assignment, no description rewrite, no undrafting.

**Announce at start:** "I'm using the verify-pr skill on PR #N."

## Input

A PR number. The repo is `CLANK_GH_REPO` from `~/.clankrc` (default `hoxhunt/hox`). Every `gh` call takes `--repo <repo>`. Run the project's `github-access` skill first if it exists.

## Hard rules

- **Never touch the user's main checkout.** It may be on the PR branch with uncommitted work, and the user pushes from other sessions. All git work happens in a worktree you create (step 1).
- **Only push to the PR's head branch**, always with `--force-with-lease`, never `--force`.
- **Fix only what the PR caused.** A failure that is also red on the base branch is reported, not chased.
- **Stop and report** when a conflict needs a product decision you cannot infer from both sides, when a CI failure's cause is unclear after reading the logs, or when the same fix fails twice.
- **No code comments** in fixes; no `git add -A`; stage files by name.

## Process

### 1. Gather and enter a worktree

```bash
gh pr view <N> --repo <repo> --json number,title,state,isDraft,url,headRefName,baseRefName,headRefOid,mergeable,mergeStateStatus
```

If `state` is not `OPEN`, say so and stop.

Create a worktree for the PR branch and point it at the remote head:

```text
EnterWorktree({ name: "verify-<N>" })
```

```bash
git fetch origin <headRefName>
git reset --hard origin/<headRefName>
git fetch origin <baseRefName>
```

Run the project's worktree bootstrap if it exists (`.claude/skills/worktree-setup/scripts/bootstrap-worktree.sh`); pass `--skip-install` unless you will need to run tests or codegen locally. Every later command runs inside this worktree; when spawning subagents, tell them the worktree path. Leave the worktree with `ExitWorktree({ action: "remove" })` at the end.

### 2. Job 1 — conflicts

Read `mergeable`. If it is `UNKNOWN`, GitHub is still computing: wait 10 seconds and re-run the `gh pr view` from step 1, up to 6 times.

- `MERGEABLE` → no conflicts. Go to step 3.
- `CONFLICTING` → rebase.

Prefer the project's `rebase` skill when it exists:

```text
Skill({ skill: "rebase", args: "<N>" })
```

It resolves the base (including stacked PRs whose base has merged), rebases, and pushes. Without it, do the same by hand:

```bash
git rebase origin/<baseRefName>
```

For each conflicted file, read both sides and the commits that produced them before choosing. Keep the intent of the PR and the intent of the base change; a conflict in generated code (lockfiles, `*.gen.ts`, `__generated__`) is resolved by re-running the generator, not by hand-merging. When a resolution would require a product decision you cannot infer, abort the rebase, leave the worktree in place, and report which file and why.

After the rebase:

```bash
git push origin HEAD:<headRefName> --force-with-lease
```

Re-run the `gh pr view` from step 1 and confirm `mergeable` is `MERGEABLE` before moving on. A push restarts CI; step 3 waits for the new build, not the old one.

### 3. Job 2 — CI

Find the build for the current head:

```bash
gh pr view <N> --repo <repo> --json headRefOid --jq .headRefOid
bk build list --branch <headRefName> --limit 3 -o json
```

Use the build whose `commit` matches the head SHA. If there is none yet, wait 30 seconds and look again, up to 10 times. If it is `running`, `scheduled`, or `creating`:

```bash
bk build watch <BUILD_NUMBER>
```

Then branch on the final state:

- `passed` → done. Go to step 4.
- `blocked` → done; say the build is waiting on a manual unblock step.
- `failed`, `broken`, `canceled` → fix.

Prefer the project's `fix-ci-failures` skill when it exists; it reads the logs, classifies the failure, fixes, verifies locally, pushes, and watches the next build:

```text
Skill({ skill: "fix-ci-failures" })
```

Without it, read the failed job logs with `bk`, classify, and apply the matching fix:

| Failure | Action |
| --- | --- |
| Codegen diff / "not up to date" | Run the generator the log names, commit the output |
| Lint / prettier | Fix the violations |
| TypeScript | Fix the type errors |
| Test | Fix the code or the assertion; if the test is also red on the base branch, report instead |
| Agent lost / timed out / exit 137 | `bk build rebuild <BUILD_NUMBER>`; no code change |
| "Wait for ... check" | Dependent step; it resolves with its upstream |
| Unclear | Stop and report |

Verify each fix locally where the failure type allows it (lint, typecheck, the failing test), commit with the project's conventional-commit format, push with `--force-with-lease` if you rewrote history or a plain push otherwise, and watch the new build. Repeat until it passes. Two consecutive failures of the same step after a fix means stop and report.

### 4. Report

Tell the user, in five lines or fewer:

- conflicts: none / resolved (files touched) / stopped on `<file>` because …
- CI: green at `<build url>` / stopped because … (with the failing step and the log line that matters)
- what you pushed: commit subjects, or "nothing pushed"
- the PR URL

Remove the worktree before reporting, unless you stopped mid-rebase and left it for the user. Then say where it is.
