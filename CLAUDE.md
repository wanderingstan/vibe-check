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
├── PLUGIN-CLAUDE.md           # Plugin instructions for Claude
│
├── .claude-plugin/
│   └── plugin.json            # Plugin manifest
│
├── scripts/
│   ├── install.sh             # Main installer (daemon)
│   ├── install-plugin.sh      # Plugin installer (MCP + skills)
│   ├── release-homebrew.sh    # Homebrew release
│   └── query-helper.sh        # Safe DB querying
│
├── skills/                    # Claude Code skills
│   ├── claude-stats/          # Usage statistics
│   ├── search-conversations/  # Search history
│   ├── analyze-tools/         # Tool usage analysis
│   ├── recent-work/           # Recent sessions
│   ├── get-session-id/        # Session lookup
│   ├── share-session/         # Share session links
│   └── view-stats/            # Open web stats page
│
├── mcp-server/                # MCP server
│   ├── server.py              # FastMCP server
│   ├── database.py            # SQLite handler
│   └── requirements.txt       # MCP dependencies
│
└── data/                      # Runtime data
    ├── config.json            # Configuration
    └── vibe_check.db          # SQLite database
```

## Database Schema

**conversation_events** - Main event storage:
```sql
id, file_name, line_number, event_data (JSON), user_name, inserted_at (debugging only)
-- Generated columns from JSON:
event_type, event_message, event_session_id, event_git_branch, event_uuid, event_timestamp
event_model, event_input_tokens, event_cache_creation_input_tokens,
event_cache_read_input_tokens, event_output_tokens
-- Regular columns:
git_remote_url, git_commit_hash, synced_at
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

## Testing Local Changes

**IMPORTANT**: When testing code changes in the local repository:

```bash
# Use direct Python invocation (runs local code)
python3 vibe-check.py
python3 vibe-check.py --skip-backlog

# NOT this (runs installed Homebrew version)
vibe-check start
```

The `vibe-check` command calls the installed Homebrew version and will not reflect recent code changes. Always use `python3 vibe-check.py` when testing local modifications.

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
