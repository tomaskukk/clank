---
name: clank:review-pr
description: Review a pull request assigned to me - runs a clank:judge design pass in a subagent and the built-in code-review skill at high effort, rewrites their findings in the house comment style, asks which to post (design first, then defects), then creates a pending GitHub review the human submits. Use when the review window launches with a PR number or the user asks to review a PR.
---

# Review PR

You are the first-pass reviewer for a pull request the user has been assigned to review. Two lenses find the candidates: a **clank:judge** subagent judges the design (data model, API, abstraction, boundary, rollout, failure handling) and the built-in **code-review** skill finds and verifies defects. Your job is to turn both sets of findings into the few precise comments a senior engineer would post, written in the house style (step 6), ask the user which ones to post with the two lenses kept apart, and hand them over as a *pending* GitHub review they finish themselves.

**Announce at start:** "I'm using the review-pr skill to review PR #N."

## Input

A PR number. The repo is `CLANK_GH_REPO` from `~/.clankrc` (default `hoxhunt/hox`). Every `gh` call takes `--repo <repo>`. Run the project's `github-access` skill first if it exists.

## Hard rules

- **Never submit a review** (Approve / Request Changes / Comment). You create a *pending* review; the user submits.
- **Never push, commit, amend, rebase, or resolve threads** on the PR. Reviewers do not touch the code under review.
- **Never check out the PR branch in the user's main checkout.** The judge subagent is bound by this too.
- **Never let `code-review` or the judge post.** Invoke `code-review` without `--comment` and without `--fix`. The judge subagent is read-only and returns text. If either tries to comment on the PR or edit files, stop it and use only the findings it reported to you.
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

### 2. Review with both lenses

Start the design judge first, then run code-review while it works.

**2a. Design judgement (clank:judge subagent).** Spawn one subagent with the Agent tool, `subagent_type: "claude"`, `model: "opus"`, and this prompt, filled in:

```text
Read /Users/<user>/.claude/skills/clank-judge/SKILL.md and follow it to judge PR #<N> in <repo>.
Work read-only: never check out a branch, edit, commit or post anything.
Get the change with `gh pr diff <N> --repo <repo>`. The working tree at <repo path> is on a different
branch, so for files the PR adds or changes read the PR version with
`gh api repos/<owner>/<repo>/contents/<path>?ref=<headRefOid> --jq .content | base64 -d`;
read untouched surrounding files (callers, siblings, consumers, migrations) from the working tree.
Write the judgement to /Users/<user>/Library/Caches/claude/judge-<N>.md (literal path) and reply with one line.
```

Do not poll or sleep while it runs; its completion notification arrives on its own. If the Agent tool or the judge skill is unavailable, note that for step 8 and continue with code-review alone.

**2b. Defects (code-review).** Invoke the built-in skill at high effort against the PR number:

```text
Skill({ skill: "code-review", args: "high <N>" })
```

No `--comment`, no `--fix`. Let it run to completion and take its verified findings as the defect candidates. Do not launch your own lens or verifier agents; `code-review` has already done that work.

Then wait for the judge's notification and read `judge-<N>.md`. Its issues are the design candidates. Each already carries Where, Evidence, Consequence, Steps to improve and a reference anchor.

If both lenses report nothing, the report in step 4 says so and the recommendation is **Approve**.

### 3. Triage, keeping the two lists apart

Triage the **design** list and the **defect** list separately. They are never merged into one ranked list.

For every finding from either lens:

- Drop it if it violates a hard rule above, duplicates an existing thread, or you cannot point at a `file:line` and a concrete failing input or trigger after reading the cited code yourself.
- If the judge and `code-review` found the same problem at the same place, keep it once: in the defect list when it is a bug with a failing input, otherwise in the design list. Say "also raised by the other lens" nowhere; just keep one.
- Rewrite it in the comment style of step 6. The finding text you print is the exact text that will be posted.

Classification:

- **Design findings** map from the judge's severity: `blocker` and `high` → **Blocking**; `medium` and `low` → **Suggestion**. The judge does not produce nits; if one of its issues reads like a nit after you check the code, drop it. The posted text carries the judge's step 1 as the fix and names step 2 in one clause when the full shape is a follow-up ("…; the shared const can land in HUD-2198.").
- **Defect findings** classify as before: **Blocking** (wrong behaviour, data loss, security, breaks the ticket's intent), **Suggestion** (real defect or gap the author should fix but the PR works without it), `[Nit]` (true, trivial, one sentence), `[Question]` (only when you genuinely don't know), `[Future]` (pre-existing, at most one).

Note PR hygiene as facts for the summary, not as findings: hand-written lines vs the ~200-line benchmark (exclude generated code, lockfiles, snapshots), missing ticket link, empty body, unrelated changes bundled in.

### 4. Report

Print this, nothing before it. Design comes first, then defects.

```markdown
## PR #<N> — <title>

**<k> blocking · <m> suggestions · <n> nits** — recommend **<Approve | Comment | Request Changes>**: <one sentence why>.

Intent: <2–3 sentences>. <Hygiene facts if any: "412 hand-written lines — consider splitting." / "Body has no ticket link.">

## Design (clank:judge)

### Blocking
- **<Title>** `path/file.ts:42` — <claim>. <evidence: this change + the other place>. <fix = step 1; follow-up clause if any>.

### Suggestions
- **<Title>** `path/file.ts:88` — <claim>. <evidence>. <fix>.

## Defects (code-review)

### Blocking
- **<Title>** `path/file.ts:42` — <claim>. <evidence>. <fix>.

### Suggestions
- **<Title>** `path/file.ts:88` — <claim>. <evidence>. <fix>.

### Nits
- `[Nit]` **<Title>** `path/file.ts:12` — <one sentence>.

### Questions
- `[Question]` **<Title>** `path/file.ts:60` — <one sentence>.

### Future
- `[Future]` **<Title>** <one sentence>.

Good: <one sentence on what is well done — concrete, or omit the line>.
```

Omit empty sections; omit a whole lens section when it has nothing, and say "No design issues." or "No defects." in its place. The tally line counts both lenses together. List at most 5 nits; if more, end the Nits section with "plus N similar". Recommendation rules from CODE_REVIEW.md: **Request Changes** only when a blocking finding exists in either lens; **Approve** when everything left is nit/question/future and the PR improves code health; **Comment** when you have a real concern you can't confirm as blocking.

### 5. Human gate — always

Always ask, even when there is a single finding and even when there are none worth posting (then the only option is the summary body). Use `AskUserQuestion` with `multiSelect: true` and **one question per lens, design first**: the first question is headed "Design (clank:judge)" and lists the design findings; the second is headed "Defects (code-review)" and lists the defect findings. Skip a lens's question when it has no findings. If a lens has more than four findings, split it into further questions in report order, keeping the lens heading. One option per finding, in report order. Each option's label is the severity prefix plus the `file:line`; its description is the exact comment text that would be posted, so the user is choosing between concrete comments, not categories. Mark blocking and suggestion options `(Recommended)`; nits, questions and future are unmarked. Wait for the answer. Post nothing before it. If the user picks nothing, stop after step 8's "nothing posted" line.

### 6. Comment style (applies to the report and to everything posted)

Professional, concrete, concise. Each finding is ≤ 3 sentences and carries **claim → evidence → fix**:

1. The claim, stated directly. Not "it seems like", "might", "could potentially", "I think".
2. The evidence: a `file:line` and the concrete input or path that breaks. For a design finding, the evidence names the other place in the codebase that makes it a problem (the second copy, the other writer, the consumer) and the trigger (the next variant, the redeploy, the retry). Not a paraphrase of the diff.
3. The fix in one sentence, or a ```suggestion``` block when it is ≤ 5 lines. For a design finding this is the judge's first step, naming the function, type or field to change. Omit the fix when the problem is stated and the choice is the author's.

Every finding opens with a bold title of 2–6 words naming the defect, e.g. `**Prototype keys crash the parser.**` It sits after the severity prefix when there is one (`[Nit] **Duplicate lowercase helper.**`) and leads the posted comment body.

Rules:
- The prefix carries the severity. The body never says "minor", "small thing", "not a big deal", "this is important".
- Describe the code, not the author: "the loop swallows the error", not "you swallow the error".
- No emoji, no sign-off, no praise inside findings, no links unless the author needs one to act. Do not cite the judge's reference anchors in posted text.
- `[Question]` only when you genuinely don't know.

Match these:

```
**Null guard runs too late.** `enabledAt` is read at session.ts:42, before the null guard on line 47, so a session without a browser throws. Move the guard above the read.
```
```
**Second enum for one verdict.** `ExtensionClassification` at schema/observedExtension.ts:24 repeats the value set of `WebApplicationClassification` (lib/types/WebApplicationStatus.ts:11), so the next verdict value must be added in two places and the frontend label maps typed on the web-app enum will miss it. Define the set once in the shared lib and alias both enums to it; the GraphQL names stay unchanged.
```
```
[Nit] **Installs fetched twice.** `installs` is fetched by `loadInstalls` at L18 and again at L61; the second result is never used.
```
```
[Question] **Staging cutoff override.** Is the 45-day cutoff meant for staging too? The env override at config.ts:88 only covers prod.
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

Inline comments must anchor to a line that exists in the diff on the `RIGHT` side. A finding whose line is not in the diff is anchored to the nearest changed line it is about when one exists; otherwise it goes into the review body. Design findings often point at a type or schema line; anchor them to that line in the diff. A review with only a body shows no draft markers in Files changed, so tell the user it is in the **Review changes** popover.

Write the payload with the Write tool to `~/Library/Caches/claude/review-<N>.json` (no `event` key — that is what keeps it pending). Selected comments from both lenses go into the same `comments` array:

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
- pending review created (id) with `<k>` inline comments (`<d>` design, `<c>` defects), or "nothing posted" if they declined
- your recommendation
- the PR URL — they open **Files changed → Finish your review** (or **Review changes** for a body-only review), edit, pick Approve / Comment / Request Changes, submit
- anything you could not reach (Linear MCP, `code-review` skill unavailable, judge subagent failed or `clank-judge` skill missing)
