---
name: claude-stats
description: Query Claude Code usage statistics from the vibe-check database. Use when user says "claude stats", "usage stats", "my claude usage", or "how much have I used claude".
---

# Claude Usage Statistics

**Purpose:** Query the local vibe-check database to show Claude Code usage statistics using the MCP server

---

## Using the MCP Tool

The vibe-check MCP server provides a `vibe_stats` tool that handles all statistics queries automatically.

### Tool: `mcp__vibe-check__vibe_stats`

**Parameters:**
- `days` (optional): Limit to last N days
- `repo` (optional): Filter to specific repository name

---

## Usage Flow

When user requests statistics:

1. **Extract filters** from user's question:
   - Time range (if specified) → convert to `days` parameter
   - Repository (if specified) → use `repo` parameter

2. **Call the MCP tool** with appropriate parameters

3. **Present results** - the tool returns formatted output with:
   - Overview (total events, sessions, days active, date range)
   - Event type breakdown with percentages
   - Top repositories with session and event counts
   - Recent daily activity

4. **Offer follow-up actions** based on the data shown

---

## Example Interactions

### Example 1: Overall Stats

```
User: "show me my claude stats"

Claude: [Calls mcp__vibe-check__vibe_stats with no parameters]

[Tool returns formatted stats including overview, event types, top repos, daily activity]
```

### Example 2: Recent Stats

```
User: "how much have I used Claude in the last 7 days?"

Claude: [Calls mcp__vibe-check__vibe_stats with days=7]

[Tool returns filtered stats for last 7 days]
```

### Example 3: Repo-Specific Stats

```
User: "show me stats for the vibe-check project"

Claude: [Calls mcp__vibe-check__vibe_stats with repo="vibe-check"]

[Tool returns stats filtered to vibe-check repository]
```

### Example 4: Combined Filters

```
User: "how much did I work on my-app in the last month?"

Claude: [Calls mcp__vibe-check__vibe_stats with days=30, repo="my-app"]

[Tool returns stats for my-app in last 30 days]
```

---

## Related Tools

Use these complementary MCP tools:

- **`mcp__vibe-check__vibe_recent`**: Show recent sessions with details
- **`mcp__vibe-check__vibe_search`**: Search for specific conversations
- **`mcp__vibe-check__vibe_tools`**: Analyze which tools are used most
- **`mcp__vibe-check__vibe_open_stats`**: Open web-based stats page in browser

---

## Error Handling

The MCP tool handles errors automatically:

- If database not found, it provides helpful file path information
- If database is empty, it explains that no data has been collected yet
- All database locking is handled internally with read-only mode

---

## Tips

- Use without parameters first to get overall picture
- Add `days` parameter to focus on recent activity
- Add `repo` parameter to see project-specific usage
- Use `vibe_open_stats` to open the web interface for interactive exploration
- Use `vibe_tools` for detailed analysis of which Claude tools you use most

---

## Advanced: Custom SQL Queries

For custom statistics not covered by `vibe_stats`, use the `mcp__vibe-check__vibe_sql` tool:

```python
mcp__vibe-check__vibe_sql(
    query="SELECT DATE(event_timestamp), COUNT(*) FROM conversation_events GROUP BY DATE(event_timestamp)",
    limit=100
)
```

This provides read-only access to the full database with custom SQL. See the vibe-check-sql skill for more examples.

For schema information, see `~/.vibe-check/SCHEMA.md` (auto-generated) or use the Read tool.
