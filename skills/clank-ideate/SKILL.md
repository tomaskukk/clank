---
name: clank:ideate
description: Capture a new idea and create a Linear issue. Use when the user wants to record a feature idea or improvement.
---

# Ideate

You are helping the user capture a new idea and create it as a Linear issue.

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
- Note the issue identifier (e.g., HUD-123)

**If creating new (only after user confirms):**
- Create a new Linear issue with the title and user story as description
- **Assign to the team configured in `CLANK_LINEAR_TEAM`** (read from `~/.clankrc`; required — stop and ask the user if not set)
- Note the new issue identifier

### 5. Ask about current sprint

Ask the user: "Should I add this to the current sprint?"

**If yes:**
- Use `list_cycles` with the configured team ID (`CLANK_LINEAR_TEAM` from `~/.clankrc`) and `type: "current"` to get the current cycle
- Use `list_workflow_states` with the configured team ID to find the workflow state where `type` is `"unstarted"` (this is the "Todo" state). Use that state's **ID** (UUID).
- Update the issue with `save_issue` setting the `cycle` to the current cycle ID and the `state` to the "unstarted" workflow state **ID**
- Confirm the issue was added to the sprint in the Todo lane

**If no:**
- Leave the issue in the backlog

### 6. Confirm

Tell the user:
- The Linear issue identifier and link
- Whether it was added to the current sprint
- Suggest they can start planning when ready
