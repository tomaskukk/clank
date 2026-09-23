---
name: clank:review-pr
description: Review a pull request assigned to me - multi-lens analysis, per-finding verification, terse findings, then a pending GitHub review the human submits. Use when the review window launches with a PR number or the user asks to review a PR.
---

# Review PR

You are the first-pass reviewer for a pull request the user has been assigned to review. Your job is to surface the few findings a senior engineer would actually act on, prove each one, and hand them to the user as a pending GitHub review they finish themselves.

**Announce at start:** "I'm using the review-pr skill to review PR #N."

## Input

A PR number. The repo is `CLANK_GH_REPO` from `~/.clankrc` (default `hoxhunt/hox`). Every `gh` call takes `--repo <repo>`. Run the project's `github-access` skill first if it exists.

## Hard rules

- **Never submit a review** (Approve / Request Changes / Comment). You create a *pending* review; the user submits.
- **Never push, commit, amend, rebase, or resolve threads** on the PR. Reviewers do not touch the code under review.
- **Never check out the PR branch in the user's main checkout.** Read the code in a throwaway worktree.
- **If you are not certain a finding is real, do not report it.** A false positive costs the author a round trip and costs you the user's trust.
- **Do not report** style, formatting, naming preferences, anything a linter/typechecker/CI catches, hypothetical runtime issues you can't reproduce from the code, or pre-existing problems the PR did not introduce (mention at most one, tagged `[Future]`, only if serious).

## Process

### 1. Gather

```bash
gh pr view <N> --repo <repo> --json number,title,body,author,isDraft,baseRefName,headRefName,headRefOid,additions,deletions,changedFiles,reviewDecision,url
gh pr diff <N> --repo <repo>
gh pr diff <N> --repo <repo> --name-only
gh api repos/<owner>/<repo>/pulls/<N>/comments
gh api repos/<owner>/<repo>/issues/<N>/comments
gh pr view <N> --repo <repo> --json reviews
```

Read existing threads first. Do not repeat a point someone already made; if a thread is open and you agree, say so in the summary instead of re-raising it.

Read the code at the PR head in an isolated worktree so subagents and LSP see real files:

```text
EnterWorktree({name: "review-<N>"})
git fetch origin <headRefName>
git reset --hard origin/<headRefName>
```

Read-only. When done, `ExitWorktree({action: "remove"})`. Tell every subagent the worktree path and that it must read only from there.

### 2. Understand intent

- Extract the Linear ticket from the body's first line (`Closes X-123` / `part of X-123` / `ref X-123`). Read it with the Linear MCP `get_issue`. If MCP is unavailable, continue without it and say so in the report.
- Write a 2–3 sentence statement of what the PR is meant to do. Every later finding is judged against this — a change that does what the ticket asks is not a bug because you'd have designed it differently.
- Note PR hygiene as facts for the summary, not as findings: hand-written lines vs the ~200-line benchmark (exclude generated code, lockfiles, snapshots), missing ticket link, empty body, unrelated changes bundled in.

### 3. Lenses (parallel subagents)

Launch these in one message, each with: the intent statement, the diff, the changed-file list, the worktree path, and the instruction "read surrounding code before claiming anything; return candidates only, each with `file:line`, the concrete failing input or scenario, and a confidence 1–10; return an empty list if nothing is certain."

| Lens | Looks for |
| --- | --- |
| **Design** | Does the change fit the existing architecture and the AGENTS.md of the touched directories? New concept where an existing one fits? Duplicates a helper that already exists in the package? |
| **Functionality** | Wrong results, off-by-one, null/undefined paths, race conditions, unhandled branches, broken invariants, behaviour that contradicts the ticket. |
| **Tests** | Behavioural coverage of the new paths, not line coverage. Missing negative case for a new guard. Tests that pass without exercising the change. Test descriptions must start with `should`. |
| **Silent failures** | Catch blocks that swallow, `.catch(() => {})`, unawaited promises, errors logged and ignored where the caller needs to know, fallbacks that hide misconfiguration. |
| **Security** | Input validation at boundaries, authz on new handlers/resolvers, tenant scoping on queries, secrets, PII in logs, injection. If the diff touches auth/authz, crypto, data-access controls, external API surface, infra (Terraform, CI, deploy), or secrets handling, invoke `/security-review` in addition — CODE_REVIEW.md requires that depth. |

Skip a lens that obviously does not apply (a docs-only PR needs no tests lens). Skip all lenses for lockfile-only or generated-only diffs and report "nothing to review".

### 4. Verify

For every candidate with confidence ≥ 6, launch a verifier subagent (parallel, one per candidate) with the candidate, the diff, and the worktree path. Its only question: **"Is this real? Confirm with a `file:line` citation and the concrete input that triggers it, or reject."** It must read the cited code, not reason from names.

Keep findings the verifier confirms at ≥ 8/10. Drop the rest without mention. Merge duplicates across lenses. Rank: blocking first, then by blast radius.

### 5. Report

Print this, nothing before it:

```markdown
## PR #<N> — <title>

**<k> blocking · <m> suggestions · <n> nits** — recommend **<Approve | Comment | Request Changes>**: <one sentence why>.

Intent: <2–3 sentences>. <Hygiene facts if any: "412 hand-written lines — consider splitting." / "Body has no ticket link.">

### Blocking
- `path/file.ts:42` — <claim>. <evidence>. <fix>.

### Suggestions
- `path/file.ts:88` — <claim>. <evidence>. <fix>.

### Nits
- `[Nit]` `path/file.ts:12` — <one sentence>.

### Questions
- `[Question]` `path/file.ts:60` — <one sentence>.

### Future
- `[Future]` <one sentence>.

Good: <one sentence on what is well done — concrete, or omit the line>.
```

Omit empty sections. List at most 5 nits; if more, end the Nits section with "plus N similar". Recommendation rules from CODE_REVIEW.md: **Request Changes** only when a blocking finding exists; **Approve** when everything left is nit/question/future and the PR improves code health; **Comment** when you have a real concern you can't confirm as blocking.

### 6. Comment style (applies to the report and to everything posted)

Each finding is ≤ 3 sentences: **claim → evidence → fix**.

1. State the defect as fact. Not "it seems like", "might", "could potentially", "I think".
2. Evidence is a `file:line` and the concrete input or path that breaks. Not a paraphrase of the diff.
3. The fix is one sentence, or a ```suggestion``` block instead of prose when it is ≤ 5 lines. Omit the fix when the problem is stated and the choice is the author's.

Rules:
- The prefix carries the severity. The body never says "minor", "small thing", "not a big deal", "this is important".
- No preamble ("I noticed that", "Just a thought", "One thing worth mentioning"), no praise inside findings ("Nice work here, but"), no sign-off, no emoji, no links unless the author needs one to act.
- Comment on the code, never the author: "the loop swallows the error", not "you swallow the error".
- `[Question]` only when you genuinely don't know. If you know, state it.
- Do not restate what the diff shows. Do not explain a principle the author already knows; explain *why* only when the reason is non-obvious.
- Write so the sentence can be read exactly one way. Concise and precise, not short and vague.

Match these:

```
`enabledAt` is read at session.ts:42 before the null guard on line 47, so a session without a browser throws. Move the guard above the read.
```
```
[Nit] `installs` is fetched twice — `loadInstalls` at L18 and again at L61; the second result is unused.
```
```
[Question] Is the 45-day cutoff intended for staging too? The env override at config.ts:88 only covers prod.
```

Never write these:

```
I noticed that it might be worth considering whether the null check here could potentially be moved earlier, since there's a small chance that...
```
```
Great job on this! One minor thing — you might want to look at the error handling.
```

### 7. Human gate

Ask the user which findings to post (default: all blocking + suggestions; nits and questions only if the user says so). Wait for the answer. Do not post anything before it.

### 8. Create the pending review

Check for an existing pending review first — GitHub allows one per user per PR:

```bash
gh api repos/<owner>/<repo>/pulls/<N>/reviews --jq '.[] | select(.state == "PENDING") | .id'
```

If one exists, stop and tell the user to submit or discard it in GitHub before you can create another.

Inline comments must anchor to a line that exists in the diff on the `RIGHT` side. A finding whose line is not in the diff goes into the review body instead.

Write the payload with the Write tool to `~/Library/Caches/claude/review-<N>.json` (no `event` key — that is what keeps it pending):

```json
{
  "commit_id": "<headRefOid>",
  "body": "<tally line + recommendation + anything not anchorable>",
  "comments": [
    { "path": "packages/x/y.ts", "line": 42, "side": "RIGHT", "body": "<finding text, prefix included>" }
  ]
}
```

Then:

```bash
gh api repos/<owner>/<repo>/pulls/<N>/reviews --method POST --input /Users/<user>/Library/Caches/claude/review-<N>.json --jq '.id, .state'
```

### 9. Confirm

Tell the user, in four lines or fewer:
- pending review created (id) with `<k>` inline comments, or "nothing posted" if they declined
- your recommendation
- the PR URL — they open **Files changed → Finish your review**, edit, pick Approve / Comment / Request Changes, submit
- any lens you skipped or MCP you could not reach

Then `ExitWorktree({action: "remove"})`.
