---
name: clank:verify-pr
description: Verify a completed PR - wait for CI, assign reviewers, write PR description. Use when a plan has been executed and has a PR reference that needs verification and review setup.
---

# Verify PR

You are helping the user verify and finalize a pull request linked to a completed plan.

## Input

You receive a plan file path as context. Read the plan file and extract:
- `pr:` — the PR reference (e.g., `org/repo#42`)
- `linear:` — the Linear issue reference (e.g., `PRJ-123`)
- `title:` — the feature title

If `pr:` is missing from the frontmatter, tell the user this plan doesn't have a PR yet and stop.

## Process

### 1. Parse PR reference

Extract the owner, repo, and PR number from the `pr:` field.

Run:
```bash
gh pr view <number> --repo <owner/repo> --json title,state,statusCheckRollup,assignees,reviewRequests
```

### 2. Check CI status

Poll CI checks until they complete:
```bash
gh pr checks <number> --repo <owner/repo>
```

- If checks are still running: wait 30 seconds, then check again (up to 10 retries)
- If checks pass: proceed to step 3
- If checks fail: report the failures to the user and stop. Do NOT proceed with review requests on a failing PR.

### 3. Ensure assignee

Check if the PR has an assignee. If not, ask the user who should be assigned:
```bash
gh pr edit <number> --repo <owner/repo> --add-assignee <username>
```

### 4. Generate PR description

Write a concise PR description with this structure:

```markdown
## Summary
<2-3 sentences describing what this PR does and why>

## Linear Issue
<Linear issue identifier and link>

## Changes
<Bulleted list of key changes, derived from the plan file>

## Testing
<How to test, derived from the plan's test steps>
```

Update the PR:
```bash
gh pr edit <number> --repo <owner/repo> --body "<description>"
```

### 5. Request review

Ask the user who should review the PR:
```bash
gh pr edit <number> --repo <owner/repo> --add-reviewer <username>
```

### 6. Update plan status

Update the plan file's frontmatter to set `status: verified`.

### 7. Confirm

Tell the user:
- CI status (passed)
- Assignee
- Reviewer(s) requested
- PR description updated
- Link to the PR
