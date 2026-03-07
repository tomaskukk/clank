---
name: clank:ideate
description: Capture a new idea with a user story and link it to Linear. Use when the user wants to record a feature idea or improvement.
---

# Ideate

You are helping the user capture a new idea and link it to Linear.

## Process

Follow these steps exactly:

### 1. Gather the idea

Ask the user for a **one-liner** describing the idea. From their response, infer:
- **Title**: A short, descriptive title
- **User Story**: "As a [role], I want [capability] so that [benefit]"

If the user already provided enough context in their message, skip asking and go straight to step 2.

### 2. Check Linear MCP availability

Before searching, verify the Linear MCP server is available by attempting a search call.

**If the Linear MCP tools are not available or return an authentication/connection error:**
- Tell the user: "Linear MCP is not available. Please authenticate by running: `claude mcp add linear`"
- **Do NOT skip Linear integration.** Stop and wait for the user to authenticate and retry.

### 3. Search Linear for existing issues

Use the Linear MCP tools to search for issues matching the idea title and description.

Present results to the user:
- If matching issues found: show them and ask which to link (or create new)
- If no matches: tell the user no matches were found

**Always ask the user** whether they want to:
1. Link to an existing issue (provide the identifier), or
2. Create a new Linear issue

**Never create a new issue without explicit user confirmation.**

### 4. Link or create Linear issue

**If linking to existing:**
- Note the issue identifier (e.g., PRJ-123)

**If creating new (only after user confirms):**
- Create a new Linear issue with the title and description from step 1
- **Always assign to team HUD**
- Note the new issue identifier

### 5. Write the idea file

Create the file at `~/.claude/ideas/YYYY-MM-DD-<slug>.md` where:
- `YYYY-MM-DD` is today's date
- `<slug>` is the title lowercased, spaces replaced with hyphens, special chars removed

Use this exact format:

```yaml
---
title: <title>
linear: <issue identifier, e.g. PRJ-123>
status: idea
created: <today's date YYYY-MM-DD>
---

## User Story
<user story>
```

### 6. Confirm

Tell the user:
- The idea file path
- The Linear issue link
- Suggest they move to the **plan** window to brainstorm and create an implementation plan
