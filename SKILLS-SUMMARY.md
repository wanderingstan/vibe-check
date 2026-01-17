# Claude Code Skills - Setup Complete!

## What Was Created

I've created **4 Claude Code skills** that enable Claude to query your local conversation database:

### 1. [claude-stats.md](~/.claude/skills/claude-stats.md)
**Triggers:** "claude stats", "usage stats", "my claude usage"

Shows comprehensive usage statistics including:
- Total events, sessions, and days active
- Event type breakdown (assistant, user, system, etc.)
- Daily activity trends
- Repository usage patterns

**Example output:**
```
📊 Claude Code Usage Statistics

Overview:
- Total events: 3,321
- Sessions: 153
- Days active: 6
- First use: 2026-01-08
- Last use: 2026-01-13

Event Types:
- assistant: 1,718 (51.7%)
- user: 1,132 (34.1%)
- file-history-snapshot: 288 (8.7%)

Last 7 Days Activity:
  2026-01-13: 4 sessions, 429 events
  2026-01-12: 9 sessions, 166 events
  ...
```

### 2. [search-conversations.md](~/.claude/skills/search-conversations.md)
**Triggers:** "search my conversations", "find when I talked about X"

Search capabilities:
- Full-text search across all messages
- Filter by date range
- Filter by repository
- Find sessions by topic
- View full conversation context

### 3. [analyze-tools.md](~/.claude/skills/analyze-tools.md)
**Triggers:** "what tools do I use most", "tool usage stats"

Analyzes Claude's tool usage:
- Most frequently used tools (Read, Bash, Edit, etc.)
- Tool usage trends over time
- Tool usage by repository
- Common tool combinations
- Tool-intensive sessions

### 4. [recent-work.md](~/.claude/skills/recent-work.md)
**Triggers:** "what have I been working on", "recent work", "what did I do today"

Shows recent activity:
- Today's sessions with context
- This week's summary
- Session duration and message counts
- First user message for context
- Repository and branch information

## Helper Files Created

### [query-helper.sh](query-helper.sh)
Utility script for querying the database with read-only mode (avoids locks):

```bash
./query-helper.sh /path/to/vibe_check.db "SELECT * FROM conversation_events LIMIT 5"
```

### [SKILLS-README.md](SKILLS-README.md)
Comprehensive documentation on:
- How skills work
- Database schema reference
- Query examples
- Troubleshooting guide
- Extension instructions

## How to Use

### Quick Start

Just ask Claude in natural language:

```
You: "claude stats"
You: "what have I been working on today?"
You: "search my conversations for authentication"
You: "what tools do I use most?"
```

Claude will automatically:
1. Recognize the trigger phrase
2. Read the corresponding skill file
3. Query the database
4. Format and present the results

### Manual Queries

You can also query the database directly:

```bash
# Using read-only mode (recommended when monitor is running)
sqlite3 "file:$HOME/Developer/vibe-check/vibe_check.db?mode=ro" \
  "SELECT COUNT(*) FROM conversation_events;"

# Using the helper script
./query-helper.sh ~/Developer/vibe-check/vibe_check.db \
  "SELECT event_type, COUNT(*) FROM conversation_events GROUP BY event_type;"
```

## Database Schema

The database tracks all your Claude Code conversations with rich metadata:

```sql
conversation_events (
    id,                    -- Auto-increment ID
    file_name,             -- Conversation file path
    line_number,           -- Line in conversation file
    event_data,            -- Full JSON event
    user_name,             -- Your username
    inserted_at,           -- When recorded
    event_type,            -- user/assistant/system (extracted)
    event_message,         -- Message content (extracted)
    event_git_branch,      -- Git branch (extracted)
    event_session_id,      -- Session ID (extracted)
    event_uuid,            -- Event UUID (extracted)
    event_timestamp,       -- Event timestamp (extracted)
    git_remote_url,        -- Git repo URL
    git_commit_hash        -- Git commit hash
)
```

All extracted fields have indexes for fast querying.

## Current Stats

Based on your database:
- **3,321 total events** recorded
- **153 sessions** across 6 days
- **Event types:** 51.7% assistant, 34.1% user
- **Most active day:** 2026-01-09 (86 sessions, 1,473 events)
- **Primary repository:** vibe-check

## Next Steps

### Try the Skills

1. Ask: **"claude stats"** to see your full usage
2. Ask: **"what did I work on yesterday?"** to see recent sessions
3. Ask: **"search my conversations for [topic]"** to find specific discussions
4. Ask: **"what tools do I use most?"** to analyze tool patterns

### Customize

The skills are markdown files in `~/.claude/skills/` - you can:
- Add new trigger phrases
- Modify queries
- Change output formats
- Create new skills

### Extend

Create your own skills by:
1. Creating a `.md` file in `~/.claude/skills/`
2. Adding trigger phrases in the header
3. Documenting the queries to run
4. Claude will automatically recognize it

## Troubleshooting

**Database locked error?**
- Always use read-only mode: `?mode=ro`
- Or use the query-helper.sh script

**No results?**
- Check if monitor is running and collecting data
- Verify date ranges in queries
- Try broader search terms

**Database not found?**
- Check: `~/.vibe-check/vibe_check.db`
- Or: `~/Developer/vibe-check/vibe_check.db`
- Ensure monitor is installed and running

## Files Reference

### In ~/.claude/skills/
- `claude-stats.md` - Usage statistics skill
- `search-conversations.md` - Conversation search skill
- `analyze-tools.md` - Tool analysis skill
- `recent-work.md` - Recent activity skill

### In ~/Developer/vibe-check/
- `query-helper.sh` - Database query helper
- `SKILLS-README.md` - Detailed documentation
- `SKILLS-SUMMARY.md` - This file
- `vibe_check.db` - SQLite database

## Resources

- [Main README](README.md) - vibe-check installation
- [Monitor Script](vibe-check.py) - Data collection
- [Schema](server-php/schema.sql) - Database schema

---

**You're all set!** Just ask Claude about your usage in natural language and it will query the database for you.
