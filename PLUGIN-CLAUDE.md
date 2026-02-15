# Vibe-Check Plugin

You have vibe-check installed - Claude Code conversation analytics and history search.

## Available MCP Tools

Use these tools to query your conversation history:

| Tool | Description | Example |
|------|-------------|---------|
| `vibe_stats` | Usage statistics (events, sessions, repos) | `vibe_stats(days=7)` |
| `vibe_search` | Search conversations by keyword | `vibe_search(query="authentication")` |
| `vibe_tools` | Analyze which tools Claude uses | `vibe_tools(days=30)` |
| `vibe_recent` | Recent sessions and activity | `vibe_recent(period="today")` |
| `vibe_session` | Get session information | `vibe_session()` |
| `vibe_share` | Create shareable session link | `vibe_share(session_id="...")` |
| `vibe_guest_messages` | Check for guest messages sent to your session | `vibe_guest_messages(action="check")` |
| `vibe_sql` | Execute raw SQL queries (read-only) | `vibe_sql(query="SELECT * FROM conversation_events LIMIT 5")` |

## Natural Language Triggers

You can also respond to natural language queries:

- **"claude stats"** / **"my usage"** -> Use `vibe_stats` tool
- **"search for X"** / **"find conversations about X"** -> Use `vibe_search` tool
- **"what tools do I use"** / **"tool analysis"** -> Use `vibe_tools` tool
- **"what have I been working on"** / **"recent work"** -> Use `vibe_recent` tool
- **"share this session"** -> Use `vibe_share` tool
- **"check my messages"** / **"any guest messages?"** -> Use `vibe_guest_messages` tool
- **"vibe sql ..."** / **"query database"** -> Use `vibe_sql` tool

## Tool Parameters

### vibe_stats
- `days` (optional): Limit to last N days
- `repo` (optional): Filter by repository name

### vibe_search
- `query` (required): Search term
- `repo` (optional): Filter by repository
- `days` (optional): Limit to last N days
- `limit` (optional): Max results (default: 20)

### vibe_tools
- `days` (optional): Days to analyze (default: 30)
- `repo` (optional): Filter by repository
- `show_combinations` (optional): Include tool pair analysis

### vibe_recent
- `period` (optional): today, yesterday, week, or month

### vibe_session
- `session_id` (optional): Specific session (default: most recent)

### vibe_share
- `session_id` (required): Session to share
- `title` (optional): Share title
- `slug` (optional): Custom URL slug

### vibe_guest_messages
- `action` (optional): Action to perform (default: "check")
  - `"check"`: View unacknowledged messages
  - `"ack"` or `"acknowledge"`: Mark messages as read and clear from server
  - `"status"`: Show polling status
  - `"refresh"`: Force immediate poll

**Note:** Guest messages are automatically polled every 30 seconds. Configure your GitHub username in VibeCheck Settings to enable this feature.

### vibe_sql
- `query` (required): SQL SELECT query to execute
- `limit` (optional): Max rows to return (default: 100, max: 1000)

**Note:** Database is read-only. Only SELECT and WITH queries are supported.

## Database

All data is stored locally in `~/.vibe-check/vibe_check.db` (SQLite).
The vibe-check daemon must be running to capture new conversations.

Check status: `vibe-check status`
View logs: `vibe-check logs`
