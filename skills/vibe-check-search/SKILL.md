---
name: search-conversations
description: Search through Claude Code conversation history. Use when user says "search my conversations", "find when I talked about X", "what did claude say about Y", or "search claude history".
---

# Search Claude Conversations

**Purpose:** Search through Claude Code conversation history using the vibe-check MCP server

---

## Using the MCP Tool

The vibe-check MCP server provides a `vibe_search` tool that handles all database queries automatically.

### Tool: `mcp__vibe-check__vibe_search`

**Parameters:**
- `query` (required): Search term to find in messages
- `repo` (optional): Filter to specific repository name
- `days` (optional): Limit to last N days
- `session_id` (optional): Search within specific session
- `limit` (optional): Maximum results (default: 20)

---

## Usage Flow

When user requests a search:

1. **Extract search criteria** from user's question:
   - Search term/keyword
   - Date range (if specified) → convert to `days` parameter
   - Repository (if specified) → use `repo` parameter
   - Session ID (if specified) → use `session_id` parameter

2. **Call the MCP tool** with appropriate parameters

3. **Present results** to user - the tool already formats them nicely

4. **Offer follow-up actions**:
   - View full session (use `vibe_session` tool)
   - Narrow search (call `vibe_search` again with more filters)
   - Open in browser (use `vibe_view` tool)

---

## Example Interactions

### Example 1: Simple Keyword Search

```
User: "search my conversations for 'authentication'"

Claude: [Calls mcp__vibe-check__vibe_search with query="authentication"]

[Tool returns formatted results showing sessions and message previews]

Would you like to:
- View full details of a specific session
- Open a session in your browser
- Search for related terms
```

### Example 2: Search with Repository Filter

```
User: "find when I worked on API endpoints in the vibe-check repo"

Claude: [Calls mcp__vibe-check__vibe_search with query="API endpoints", repo="vibe-check"]

[Tool returns filtered results]
```

### Example 3: Recent Search

```
User: "what did I work on yesterday?"

Claude: [Note: For "recent work" queries, use the vibe_recent tool instead]
        [Calls mcp__vibe-check__vibe_recent with period="yesterday"]
```

### Example 4: Search Within Session

```
User: "search for 'database' in session abc123"

Claude: [Calls mcp__vibe-check__vibe_search with query="database", session_id="abc123"]
```

---

## Related Tools

Use these complementary MCP tools:

- **`mcp__vibe-check__vibe_recent`**: Show recent sessions by time period (today, yesterday, week, month)
- **`mcp__vibe-check__vibe_session`**: Get detailed info about a specific session
- **`mcp__vibe-check__vibe_view`**: Open a session in the local web viewer
- **`mcp__vibe-check__vibe_stats`**: Show overall usage statistics

---

## Error Handling

The MCP tool handles errors automatically and provides helpful messages:

- If no results found, it suggests broader search terms and checking if monitor was running
- If database not accessible, it provides file path information
- All database locking is handled internally with read-only mode

---

## Tips

- For broad exploration of recent work, use `vibe_recent` first
- For targeted keyword searches, use `vibe_search`
- Combine filters (repo + days) to narrow results
- Use `vibe_view` to open interesting sessions in browser for full context

---

## Advanced: Custom SQL Queries

For complex queries not covered by `vibe_search`, use the `mcp__vibe-check__vibe_sql` tool:

```python
mcp__vibe-check__vibe_sql(
    query="SELECT ... FROM conversation_events WHERE ...",
    limit=100  # optional, max 1000
)
```

This provides read-only access to the full database with custom SQL. See the vibe-check-sql skill for more examples.

For schema information, see `~/.vibe-check/SCHEMA.md` (auto-generated) or use the Read tool.
