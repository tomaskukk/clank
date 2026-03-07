---
name: clank:executing-plans
description: Use when you have a written implementation plan to execute in a separate session with review checkpoints
---

# Executing Plans

## Overview

Load plan, review critically, execute tasks in batches, report for review between batches.

**Core principle:** Batch execution with checkpoints for architect review.

**Announce at start:** "I'm using the executing-plans skill to implement this plan."

## The Process

### Step 1: Load and Review Plan
1. Read plan file
2. Review critically - identify any questions or concerns about the plan
3. If concerns: Raise them with your human partner before starting
4. If no concerns: Create TodoWrite and proceed

### Step 2: Execute Batch
**Default: First 3 tasks**

For each task:
1. Mark as in_progress
2. Follow each step exactly (plan has bite-sized steps)
3. Run verifications as specified
4. Mark as completed

### Step 3: Report
When batch complete:
- Show what was implemented
- Show verification output
- Say: "Ready for feedback."

### Step 4: Continue
Based on feedback:
- Apply changes if needed
- Execute next batch
- Repeat until complete

### Step 5: Create Draft PR

After all tasks complete and verified:

1. **Run the project's test suite** to confirm everything passes
2. **Find the Linear ticket ID** — check the plan markdown file for the Linear issue reference (e.g., `RUSH-1234`)
3. **Push the branch:**
   ```bash
   git push -u origin <feature-branch>
   ```
4. **Create a draft PR with Linear link:**
   ```bash
   gh pr create --draft --title "<title>" --body "closes <LINEAR-TICKET-ID>

   Draft PR - pending review"
   ```
   The `closes <LINEAR-TICKET-ID>` line links the PR to the Linear issue.
5. **Archive the plan:** Update the plan file's frontmatter or move it to indicate it has been executed (e.g., add `status: archived` or rename to `YYYY-MM-DD-<feature-name>.archived.md`).
6. **Report to user:**
   ```
   All tasks complete. Draft PR created: <PR URL>
   Linked to Linear issue: <LINEAR-TICKET-ID>
   Plan archived.

   Head to the verify window to verify CI, assign reviewers, and finalize the PR description.
   ```

Do NOT offer other options (merge locally, discard, etc.). Always create a draft PR and direct the user to the verify window.

## When to Stop and Ask for Help

**STOP executing immediately when:**
- Hit a blocker mid-batch (missing dependency, test fails, instruction unclear)
- Plan has critical gaps preventing starting
- You don't understand an instruction
- Verification fails repeatedly

**Ask for clarification rather than guessing.**

## When to Revisit Earlier Steps

**Return to Review (Step 1) when:**
- Partner updates the plan based on your feedback
- Fundamental approach needs rethinking

**Don't force through blockers** - stop and ask.

## Remember
- Review plan critically first
- Follow plan steps exactly
- Don't skip verifications
- Reference skills when plan says to
- Between batches: just report and wait
- Stop when blocked, don't guess
- Never start implementation on main/master branch without explicit user consent

## Integration

**Required workflow skills:**
- **superpowers:using-git-worktrees** - REQUIRED: Set up isolated workspace before starting
- **clank:writing-plans** - Creates the plan this skill executes
- **clank:verify-pr** - Used in the verify window after draft PR is created
