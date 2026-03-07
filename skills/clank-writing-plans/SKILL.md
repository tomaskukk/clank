---
name: clank:writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code
---

# Writing Plans

## Overview

Write comprehensive implementation plans assuming the engineer has zero context for our codebase and questionable taste. Document everything they need to know: which files to touch for each task, code, testing, docs they might need to check, how to test it. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume they are a skilled developer, but know almost nothing about our toolset or problem domain. Assume they don't know good test design very well.

**Announce at start:** "I'm using the writing-plans skill to create the implementation plan."

**Context:** This should be run in a dedicated worktree (created by brainstorming skill).

**Save plans to:** `~/.claude/plans/YYYY-MM-DD-<feature-name>.md` (absolute path, never relative `docs/plans/`)

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Plan Document Header

**Every plan MUST start with this header:**

```markdown
# [Feature Name] Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use clank:executing-plans to implement this plan task-by-task.

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

---
```

## Task Structure

````markdown
### Task N: [Component Name]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

**Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

**Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

**Step 4: Run test to verify it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

**Step 5: Commit**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
````

## Remember
- Exact file paths always
- Complete code in plan (not "add validation")
- Exact commands with expected output
- Reference relevant skills with @ syntax
- DRY, YAGNI, TDD, frequent commits

## Plan Review & Handoff

After saving the plan, guide the user through review:

**"Plan complete and saved to `~/.claude/plans/<filename>.md`.**

**Please review the plan and leave inline comments directly in the plan file for anything you want changed — questions, corrections, missing context, or disagreements. Then come back and tell me:**

**1. Accept** — Plan looks good, ready to execute
**2. Review comments** — I left comments in the plan, please address them"

**If Accept chosen:**
- **Sync plan to Linear:** If a Linear issue identifier is referenced in the plan, post the full plan content as a comment on that Linear issue using the Linear MCP tools (`create_comment` with the issue ID and the plan markdown as the body). If the Linear MCP tools are not available, warn the user but don't block acceptance.
- Say: "Plan accepted. Head to the exec window to execute it."
- Do NOT offer execution approach choices. The exec window handles execution.

**If Review comments chosen:**
- Read the plan file and address every inline comment
- Update the plan accordingly
- Re-save and repeat the review cycle until the user accepts
