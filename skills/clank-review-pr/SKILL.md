---
name: clank:review-pr
description: Review a pull request assigned to me - runs the built-in code-review skill at high effort, rewrites its findings in the house comment style, asks which to post, then creates a pending GitHub review the human submits. Use when the review window launches with a PR number or the user asks to review a PR.
---

# Review PR

You are the first-pass reviewer for a pull request the user has been assigned to review. The built-in `code-review` skill finds and verifies the defects; your job is to turn its findings into the few terse comments a senior engineer would post, ask the user which ones to post, and hand them over as a *pending* GitHub review they finish themselves.

**Announce at start:** "I'm using the review-pr skill to review PR #N."

## Input

A PR number. The repo is `CLANK_GH_REPO` from `~/.clankrc` (default `hoxhunt/hox`). Every `gh` call takes `--repo <repo>`. Run the project's `github-access` skill first if it exists.

## Hard rules

- **Never submit a review** (Approve / Request Changes / Comment). You create a *pending* review; the user submits.
- **Never push, commit, amend, rebase, or resolve threads** on the PR. Reviewers do not touch the code under review.
- **Never check out the PR branch in the user's main checkout.**
- **Never let `code-review` post.** Invoke it without `--comment` and without `--fix`. If the loaded variant tries to comment on the PR or edit files, stop it and use only the findings it reported to you.
- **Nothing leaves the terminal before the human gate in step 5.**
- **If you are not certain a finding is real, do not report it.** A false positive costs the author a round trip and costs you the user's trust.
- **Do not report** style, formatting, naming preferences, anything a linter/typechecker/CI catches, hypothetical runtime issues you can't reproduce from the code, or pre-existing problems the PR did not introduce (mention at most one, tagged `[Future]`, only if serious).

## Process

### 1. Gather

```bash
gh pr view <N> --repo <repo> --json number,title,body,author,isDraft,baseRefName,headRefName,headRefOid,additions,deletions,changedFiles,reviewDecision,url
gh pr diff <N> --repo <repo> --name-only
gh api repos/<owner>/<repo>/pulls/<N>/comments
gh api repos/<owner>/<repo>/issues/<N>/comments
gh pr view <N> --repo <repo> --json reviews
```

Read existing threads first. A point someone already made is not repeated; if that thread is open and you agree, say so in the summary instead of re-raising it.

Extract the Linear ticket from the body's first line (`Closes X-123` / `part of X-123` / `ref X-123`) and read it with the Linear MCP `get_issue` when available. A change that does what the ticket asks is not a bug because you'd have designed it differently.

### 2. Review

Invoke the built-in skill at high effort against the PR number:

```text
Skill({ skill: "code-review", args: "high <N>" })
```

No `--comment`, no `--fix`. Let it run to completion and take its verified findings as your candidate list. Do not launch your own lens or verifier agents; `code-review` has already done that work.

If it reports nothing, the report in step 4 says so and the recommendation is **Approve**.

### 3. Triage

For each finding `code-review` returned:

- Drop it if it violates a hard rule above, duplicates an existing thread, or you cannot point at a `file:line` and a concrete failing input after reading the cited code yourself.
- Classify it: **Blocking** (wrong behaviour, data loss, security, breaks the ticket's intent), **Suggestion** (real defect or gap the author should fix but the PR works without it), `[Nit]` (true, trivial, one sentence), `[Question]` (only when you genuinely don't know), `[Future]` (pre-existing, at most one).
- Rewrite it in the comment style of step 6. The finding text you print is the exact text that will be posted.

Note PR hygiene as facts for the summary, not as findings: hand-written lines vs the ~200-line benchmark (exclude generated code, lockfiles, snapshots), missing ticket link, empty body, unrelated changes bundled in.

### 4. Report

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

### 5. Human gate — always

Always ask, even when there is a single finding and even when there are none worth posting (then the only option is the summary body). Use `AskUserQuestion` with `multiSelect: true`, one option per finding, in report order. Each option's label is the severity prefix plus the `file:line`; its description is the exact comment text that would be posted, so the user is choosing between concrete comments, not categories. Mark blocking and suggestion options `(Recommended)`; nits, questions and future are unmarked. Wait for the answer. Post nothing before it. If the user picks nothing, stop after step 7's "nothing posted" line.

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

### 7. Create the pending review

Check for an existing pending review first — GitHub allows one per user per PR:

```bash
gh api repos/<owner>/<repo>/pulls/<N>/reviews --jq '.[] | select(.state == "PENDING") | .id'
```

If one exists, stop and tell the user to submit or discard it in GitHub before you can create another.

Inline comments must anchor to a line that exists in the diff on the `RIGHT` side. A finding whose line is not in the diff is anchored to the nearest changed line it is about when one exists; otherwise it goes into the review body. A review with only a body shows no draft markers in Files changed, so tell the user it is in the **Review changes** popover.

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

### 8. Confirm

Tell the user, in four lines or fewer:
- pending review created (id) with `<k>` inline comments, or "nothing posted" if they declined
- your recommendation
- the PR URL — they open **Files changed → Finish your review** (or **Review changes** for a body-only review), edit, pick Approve / Comment / Request Changes, submit
- anything you could not reach (Linear MCP, `code-review` skill unavailable)
