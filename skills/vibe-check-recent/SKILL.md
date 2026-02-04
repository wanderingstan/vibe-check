---
name: recent-work
description: Show recent Claude Code sessions and work history. Use when user says "what have I been working on", "recent work", "what did I do today", or "show recent sessions".
---

# Recent Claude Work

**Purpose:** Show recent Claude Code sessions and what you've been working on using the MCP server

---

## Using the MCP Tool

The vibe-check MCP server provides a `vibe_recent` tool that shows recent sessions with full context.

### Tool: `mcp__vibe-check__vibe_recent`

**Parameters:**
- `period` (optional): Time period - "today", "yesterday", "week", or "month" (default: "today")
- `limit` (optional): Maximum sessions to show (default: 10)

---

## Usage Flow

When user asks about recent work:

1. **Determine time period** from user's question:
   - "today" → period="today"
   - "yesterday" → period="yesterday"
   - "this week" → period="week"
   - "this month" → period="month"

2. **Call the MCP tool** with appropriate period

3. **Present results** - the tool returns formatted output with:
   - Session ID (shortened)
   - Repository and branch
   - Duration in minutes
   - Activity counts (user/assistant messages)
   - Start time
   - First message preview

4. **Offer follow-up actions**:
   - View full session details (use `vibe_session`)
   - Open session in browser (use `vibe_view`)
   - Search for specific topics (use `vibe_search`)

---

## Example Interactions

### Example 1: Today's Work

```
User: "what did I do today?"

Claude: [Calls mcp__vibe-check__vibe_recent with period="today"]

[Tool returns list of today's sessions with context]

Would you like to:
- View details of a specific session
- Open a session in your browser
- See your overall stats
```

### Example 2: Yesterday

```
User: "what did I work on yesterday?"

Claude: [Calls mcp__vibe-check__vibe_recent with period="yesterday"]

[Tool returns yesterday's sessions]
```

### Example 3: This Week

```
User: "what have I been working on this week?"

Claude: [Calls mcp__vibe-check__vibe_recent with period="week"]

[Tool returns all sessions from the past 7 days]
```

### Example 4: More Sessions

```
User: "show me my last 20 sessions"

Claude: [Calls mcp__vibe-check__vibe_recent with period="month", limit=20]

[Tool returns up to 20 sessions from the past month]
```

---

## Related Tools

Use these complementary MCP tools:

- **`mcp__vibe-check__vibe_session`**: Get detailed info about a specific session
- **`mcp__vibe-check__vibe_search`**: Search for conversations about specific topics
- **`mcp__vibe-check__vibe_stats`**: See overall usage statistics
- **`mcp__vibe-check__vibe_view`**: Open a session in the local web viewer
- **`mcp__vibe-check__vibe_share`**: Create a shareable link for a session

---

## Error Handling

The MCP tool handles errors automatically:

- If no sessions found, it explains that the monitor may not have been running
- If database not accessible, it provides helpful file path information
- All database locking is handled internally with read-only mode

---

## Tips

- Use "today" for current day's work
- Use "week" to see broader activity patterns
- The first user message gives good context about what each session was about
- Follow up with `vibe_view` to open interesting sessions in browser
- Use `vibe_search` if you remember a specific keyword but not when you worked on it
- Use `vibe_session` with a specific session ID to get detailed information

---

## Advanced: Custom SQL Queries

For custom time-based analysis not covered by `vibe_recent`, use the `mcp__vibe-check__vibe_sql` tool:

```python
mcp__vibe-check__vibe_sql(
    query="SELECT event_session_id, COUNT(*) FROM conversation_events WHERE DATE(event_timestamp) = DATE('now') GROUP BY event_session_id",
    limit=100
)
```

This provides read-only access to the full database with custom SQL. See the vibe-check-sql skill for more examples.

For schema information, see `~/.vibe-check/SCHEMA.md` (auto-generated) or use the Read tool.
