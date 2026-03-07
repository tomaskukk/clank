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
gh pr view <number> --repo <owner/repo> --json title,state,statusCheckRollup,assignees,reviewRequests,body,headRefName,baseRefName,url,author
```

Also get the commit history and changed files:
```bash
gh pr view <number> --repo <owner/repo> --json commits --jq '.commits[].messageHeadline'
gh pr diff <number> --repo <owner/repo> --name-only
```

### 2. Check CI status

Poll CI checks until they complete:
```bash
gh pr checks <number> --repo <owner/repo>
```

- If checks are still running: wait 30 seconds, then check again (up to 10 retries)
- To check only remaining pending/failed: `gh pr checks <number> 2>&1 | grep -E "pending|fail"`
- If checks pass: proceed to step 3
- If checks fail: continue with using `check-ci-status` skill


### 3. Ensure clank didn't ship slop

Tell the user to make sure they've reviewed the draft PR well, and ensured it contains no slop.

### 4. Ask who to assign and review

Always ask the user who should be assigned to and review the PR — even if the PR already has assignees. The same person(s) should be set as both assignee and reviewer.

### 5. Generate PR description

Write a concise PR description with this structure:

```markdown
closes <LINEAR-ISSUE>

## Summary
<2-3 sentences describing what this PR does and why>

## Changes
<Bulleted list of key changes, derived from the plan file and commit history>

## Testing
<How to test, derived from the plan's test steps>
```

### 6. Apply changes via REST API

**IMPORTANT:** Do NOT use `gh pr edit` for assignees, reviewers, or body — it fails due to GitHub Projects Classic deprecation. Use the REST API instead:

**Update PR body:**
```bash
gh api repos/<owner>/<repo>/pulls/<number> -X PATCH --input - <<'EOF'
{"body":"<description>"}
EOF
```

**Assign users:**
```bash
gh api repos/<owner>/<repo>/issues/<number>/assignees -X POST --input - <<'EOF'
{"assignees":["<username1>","<username2>"]}
EOF
```

**Request reviewers:**
```bash
gh api repos/<owner>/<repo>/pulls/<number>/requested_reviewers -X POST --input - <<'EOF'
{"reviewers":["<username1>","<username2>"]}
EOF
```

### 7. Confirm

Tell the user:
- CI status (passed)
- Assignee(s) and reviewer(s) (same people)
- PR description updated
- Link to the PR
