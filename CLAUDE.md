# vibe-check (Client)

A Python monitoring client that watches Claude Code conversation files and stores them locally (SQLite) with optional remote sync.

## Related Projects

- **Server**: [vibe-check-site](https://github.com/wanderingstan/vibe-check-site) - PHP/React dashboard
  - Typically cloned to sibling directory: `../vibe-check-site/`

## Tech Stack

- **Language**: Python 3
- **File Watching**: Watchdog library
- **Database**: SQLite (local), MySQL (remote via API)
- **Secret Detection**: detect-secrets library
- **Skills**: Claude Code markdown-based skills

## Directory Structure

```
├── vibe-check.py              # Main monitoring client
├── secret_detector.py         # Secret detection/redaction
├── requirements.txt           # Python dependencies
├── config.json.example        # Config template
│
├── scripts/
│   ├── install.sh             # Main installer
│   ├── release-homebrew.sh    # Homebrew release
│   └── query-helper.sh        # Safe DB querying
│
├── claude-skills/             # Claude Code skills
│   ├── claude-stats.md        # Usage statistics
│   ├── search-conversations.md # Search history
│   ├── analyze-tools.md       # Tool usage analysis
│   ├── recent-work.md         # Recent sessions
│   └── get-session-id.md      # Session lookup
│
├── data/                      # Runtime data
│   ├── config.json            # Configuration
│   └── vibe_check.db          # SQLite database
│
└── mcp-server/                # MCP server (separate)
```

## Database Schema

**conversation_events** - Main event storage:
```sql
id, file_name, line_number, event_data (JSON), user_name, inserted_at
-- Generated columns from JSON:
event_type, event_message, event_session_id, event_git_branch, event_uuid, event_timestamp
git_remote_url, git_commit_hash
```

**conversation_file_state** - Incremental processing state:
```sql
file_name (PK), last_line, updated_at
```

## Commands

```bash
# Daemon management
vibe-check start       # Start background monitoring
vibe-check stop        # Stop monitoring
vibe-check restart     # Restart
vibe-check status      # Check if running
vibe-check logs        # View logs

# Direct Python usage
python vibe-check.py                     # Start monitoring
python vibe-check.py --skip-backlog      # Skip existing files
python vibe-check.py --skip-skills-check # Skip skills install prompt

# Database queries
./scripts/query-helper.sh <db_path> "SELECT ..."
sqlite3 "file:<db_path>?mode=ro" "SELECT ..."
```

## Configuration

**config.json**:
```json
{
  "api": {
    "enabled": false,
    "url": "https://vibecheck.wanderingstan.com/api",
    "api_key": "..."
  },
  "sqlite": {
    "enabled": true,
    "database_path": "~/.vibe-check/vibe_check.db",
    "user_name": "wanderingstan"
  },
  "monitor": {
    "conversation_dir": "~/.claude/projects"
  }
}
```

## Data Locations

**All install types use unified location:**
- DB: `~/.vibe-check/vibe_check.db`
- Config: `~/.vibe-check/config.json`
- PID: `~/.vibe-check/.monitor.pid`
- Skills: `~/.claude/skills/`

Note: Homebrew symlinks `/opt/homebrew/var/vibe-check` → `~/.vibe-check`

## Key Patterns

1. **Incremental Processing**: Only processes new lines since last run; resumes after restart
2. **Secret Detection**: Scans with detect-secrets, redacts before storage/API
3. **Read-Only Queries**: Skills use `?mode=ro` to avoid locking the DB
4. **Git Context**: Captures repo URL and commit hash with each event
5. **Non-Fatal API**: If API is down, continues with local-only storage

## Skills System

Skills are markdown files in `~/.claude/skills/` that enable natural language queries:
- "claude stats" → usage statistics
- "search my conversations for X" → full-text search
- "what tools do I use most" → tool analysis
- "what have I been working on" → recent sessions

## Key Classes (vibe-check.py)

- **StateManager**: Tracks processed file state in SQLite
- **SQLiteManager**: Local DB operations, schema creation, indexing
- **ConversationMonitor**: Watchdog event handler, processes .jsonl files
