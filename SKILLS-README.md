# Claude Code Skills for Usage Analysis

This directory contains Claude Code skills that enable Claude to query your local conversation database.

## Available Skills

### 1. Claude Stats (`claude-stats.md`)
**Usage:** "claude stats", "usage stats", "my claude usage"

Shows comprehensive usage statistics:
- Total events and sessions
- Days active
- Event type breakdown
- Daily activity trends
- Repository usage

### 2. Search Conversations (`search-conversations.md`)
**Usage:** "search my conversations for X", "find when I talked about Y"

Search through your conversation history:
- Keyword search across all messages
- Filter by date range
- Filter by repository
- View full sessions
- Find related conversations

### 3. Analyze Tools (`analyze-tools.md`)
**Usage:** "what tools do I use most", "tool usage stats"

Analyze Claude's tool usage patterns:
- Most used tools (Read, Bash, Edit, etc.)
- Tool usage trends over time
- Tools by repository
- Common tool combinations
- Tool-intensive sessions

### 4. Recent Work (`recent-work.md`)
**Usage:** "what have I been working on", "recent work", "what did I do today"

View your recent Claude sessions:
- Today's sessions
- Recent work summary
- Session duration and context
- First messages for context
- Weekly activity summary

## Database Location

Primary: `~/.vibe-check/vibe_check.db`
Fallback: `/Users/wanderingstan/Developer/vibe-check/vibe_check.db`

## How Skills Work

1. User triggers a skill with natural language
2. Claude recognizes the trigger phrase
3. Claude reads the skill markdown file for instructions
4. Claude executes appropriate SQLite queries
5. Claude formats and presents the results

## Important Notes

### Database Locks

The database may be locked if the monitor is running. Skills should use read-only mode:

```bash
sqlite3 "file:/path/to/vibe_check.db?mode=ro" "SELECT ..."
```

Or use the helper script:

```bash
./query-helper.sh /path/to/vibe_check.db "SELECT ..."
```

### Query Performance

The database uses generated columns and indexes for efficient querying:
- `event_type` - Extracted from JSON
- `event_message` - Extracted from JSON
- `event_session_id` - Extracted from JSON
- `git_remote_url` - Git repository URL
- `git_commit_hash` - Git commit at time of conversation

All have indexes for fast queries.

## Example Usage

```
You: "claude stats"
Claude: [Queries database and shows stats]

📊 Claude Code Usage Statistics

Overview:
- Total events: 3,274
- Sessions: 153
- Days active: 6
- First use: 2026-01-08
- Last use: 2026-01-13

Event Types:
- assistant: 1,690 (51.6%)
- user: 1,115 (34.1%)
- file-history-snapshot: 285 (8.7%)
...
```

```
You: "what have I been working on today?"
Claude: [Shows today's sessions with context]
```

```
You: "search my conversations for 'authentication'"
Claude: [Finds all conversations mentioning authentication]
```

## Extending Skills

To create new skills:

1. Create a markdown file in `~/.claude/skills/`
2. Add trigger phrases in the header
3. Document the queries to run
4. Specify the output format
5. Claude will automatically recognize and use it

## Troubleshooting

**"Database not found"**
- Check if vibe-check monitor is installed
- Verify database path in config
- Run monitor to start collecting data

**"Database is locked"**
- Use read-only mode: `?mode=ro`
- Stop monitor temporarily
- Use the query-helper.sh script

**"No results"**
- Check if monitor has collected data
- Verify date ranges in queries
- Try broader search terms

## Manual Queries

You can also query the database directly:

```bash
# Using read-only mode
sqlite3 "file:$HOME/Developer/vibe-check/vibe_check.db?mode=ro" \
  "SELECT * FROM conversation_events LIMIT 5;"

# Using helper script
./query-helper.sh ~/Developer/vibe-check/vibe_check.db \
  "SELECT event_type, COUNT(*) FROM conversation_events GROUP BY event_type;"
```

## Schema Reference

```sql
CREATE TABLE conversation_events (
    id INTEGER PRIMARY KEY,
    file_name TEXT NOT NULL,
    line_number INTEGER NOT NULL,
    event_data TEXT NOT NULL,           -- Full JSON event
    user_name TEXT NOT NULL,
    inserted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    event_type TEXT,                    -- Generated: user/assistant/system
    event_message TEXT,                 -- Generated: message content
    event_git_branch TEXT,              -- Generated: git branch
    event_session_id TEXT,              -- Generated: session ID
    event_uuid TEXT,                    -- Generated: event UUID
    event_timestamp TEXT,               -- Generated: timestamp
    git_remote_url TEXT,                -- Git remote URL
    git_commit_hash TEXT,               -- Git commit hash
    UNIQUE(file_name, line_number)
);
```

## Resources

- [Main README](README.md) - Installation and setup
- [Schema Documentation](server-php/schema.sql) - Full database schema
- [Monitor Script](vibe-check.py) - Data collection script
