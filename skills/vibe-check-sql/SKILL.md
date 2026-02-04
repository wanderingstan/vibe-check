---
id: vibe-check-sql
name: vibe-check SQL Query
activationKeywords:
  - vibe sql
  - query vibe-check database
  - raw sql query
  - sqlite query vibe
  - custom sql vibe
---

# vibe-check SQL Query

Execute raw SQL queries against your vibe-check conversation database.

## What This Does

Runs arbitrary SELECT queries on your local SQLite database containing Claude Code conversation history. The database is opened in **read-only mode**, so you can explore and analyze data safely without risk of corruption.

## When to Use

- Custom data exploration not covered by other tools
- Complex JOIN queries across tables
- Debugging database schema or data issues
- Learning what data is available in vibe-check

## Database Schema

**Schema documentation is auto-generated at:** `~/.vibe-check/SCHEMA.md`

This file is regenerated every time vibe-check starts, so it's always up to date with the current database structure.

You can read it with:

```bash
cat ~/.vibe-check/SCHEMA.md
```

Or use the Read tool to view it directly.

**Main tables:**

- `conversation_events` - All conversation events (user/assistant messages, tool calls, etc.)
  - Key columns: `event_type`, `event_message`, `event_session_id`, `event_git_branch`, `git_remote_url`, `event_timestamp`, `event_data` (JSON)
  - `inserted_at` is only used for debugging. Ignore.

- `messages_fts` - FTS5 full-text search index (virtual table)
  - Columns: `event_message`, `event_type`, `event_session_id`
  - Synced automatically with `conversation_events` via triggers
  - Provides fast full-text search with relevance ranking

- `conversation_file_state` - File processing state tracking
  - Columns: `file_name`, `last_line`, `updated_at`

## Examples

```sql
-- See schema
SELECT sql FROM sqlite_master WHERE type='table' AND name='conversation_events';

-- Find most common error messages
SELECT
  SUBSTR(event_message, 1, 100) as error_preview,
  COUNT(*) as occurrences
FROM conversation_events
WHERE event_message LIKE '%error%'
  AND event_type = 'assistant'
GROUP BY error_preview
ORDER BY occurrences DESC
LIMIT 10;

-- Session duration analysis
SELECT
  event_session_id,
  MIN(event_timestamp) as start_time,
  MAX(event_timestamp) as end_time,
  ROUND((JULIANDAY(MAX(event_timestamp)) - JULIANDAY(MIN(event_timestamp))) * 24, 2) as hours
FROM conversation_events
WHERE event_session_id IS NOT NULL
GROUP BY event_session_id
ORDER BY hours DESC
LIMIT 10;

-- Tool usage by repository
SELECT
  REPLACE(SUBSTR(git_remote_url, INSTR(git_remote_url, '/')+1), '.git', '') as repo,
  json_extract(value, '$.name') as tool_name,
  COUNT(*) as uses
FROM conversation_events,
     json_each(json_extract(event_data, '$.message.content'))
WHERE json_extract(value, '$.type') = 'tool_use'
  AND git_remote_url IS NOT NULL
GROUP BY repo, tool_name
ORDER BY uses DESC
LIMIT 20;

-- FTS5 full-text search with relevance ranking
SELECT
  ce.event_type,
  SUBSTR(ce.event_message, 1, 100) as preview,
  fts.rank as relevance,
  ce.event_timestamp
FROM messages_fts fts
JOIN conversation_events ce ON ce.id = fts.rowid
WHERE messages_fts MATCH 'authentication AND oauth'
ORDER BY fts.rank
LIMIT 10;

-- FTS5 phrase search
SELECT COUNT(*)
FROM messages_fts
WHERE messages_fts MATCH '"full text search"';
```

## Usage

**From Claude Code:**

- "vibe sql [your query]"
- "query vibe-check database: SELECT \* FROM conversation_events LIMIT 5"
- "run sql: SELECT COUNT(\*) FROM conversation_events"

**Via MCP Tool:**

```python
vibe_sql(
  query="SELECT * FROM conversation_events WHERE event_type = 'user' LIMIT 10",
  limit=100  # optional, defaults to 100, max 1000
)
```

## Notes

- Database is read-only - INSERT/UPDATE/DELETE will fail
- Results are automatically limited (default: 100 rows, max: 1000)
- Long strings in results are truncated to 50 characters
- Results formatted as markdown tables for readability
- Use LIMIT in your queries for better performance

## Related Tools

- `vibe_stats` - Pre-built usage statistics
- `vibe_search` - Search message content
- `vibe_tools` - Analyze tool usage patterns
- `vibe_recent` - View recent sessions
