# 🧜 Vibe-Check Claude Code Conversation Monitor

Monitors Claude Code conversation files and backs them up to a local SQLite database, and optionally sends them to the a remote server for storage.

New skills in Claude code then allow you to reference and analyze your past converstaions from within Claude!

## Installation

### MacOS Homebrew (Recommended)

The easiest way to install on macOS:

```bash
brew install wanderingstan/vibe-check/vibe-check
vibe-check start
```

This will:

- Install vibe-check with all dependencies
- Automatically install Claude Code skills to `~/.claude/skills/`
- Set up local SQLite database for your conversations
- Start monitoring your Claude Code conversations in the background

Then manage it with simple commands:

```bash
vibe-check status    # Check if running
vibe-check logs      # View logs
vibe-check restart   # Restart
```

### Linux / Other Platforms

For non-macOS systems (or macOS without Homebrew), install via curl:

```bash
curl -fsSL https://vibecheck.wanderingstan.com/install.sh | bash
```

This will:

- Install Vibe Check to `~/.vibe-check`
- Open a browser for authentication
- Install Claude Code skills to `~/.claude/skills/`
- Set up auto-start service (systemd on Linux, launchd on macOS)
- Start monitoring your Claude Code conversations

### From Git Repository

If you've cloned the repo, you can install directly:

```bash
git clone https://github.com/wanderingstan/vibe-check.git
cd vibe-check
./scripts/install.sh
```

This runs vibe-check directly from the repo (no copying to `~/.vibe-check`). Skills are still installed to `~/.claude/skills/`.

## Updating

**Homebrew:**
```bash
brew upgrade vibe-check
```

**Curl installation:**
```bash
curl -fsSL https://vibecheck.wanderingstan.com/install.sh | bash
```

**Git repo:**
```bash
git pull
./scripts/install.sh  # Updates dependencies if needed
```

## Uninstalling

**Homebrew:**
```bash
brew services stop vibe-check
brew uninstall vibe-check
rm -rf ~/.vibe-check
```

**Manual install:**
```bash
curl -fsSL https://raw.githubusercontent.com/wanderingstan/vibe-check/main/scripts/uninstall.sh | bash
```

This removes the installation and stops any running processes. Your server account remains active.

## Architecture

- **Client (vibe-check.py)**: Watches local .jsonl files and sends events to API
- **Server (server-php/)**: PHP API that authenticates requests and stores in MySQL

## Features

- Real-time monitoring using watchdog (OS-level file events)
- Incremental processing (only new lines, no reprocessing)
- State persistence (resumes after restart)
- API key authentication
- JSON blob storage (flexible for future schema changes)
- Local SQLite database for offline querying
- **Claude Code Skills for usage analysis**
- **Interactive skills installation prompt** on first run

## Claude Code Skills

Vibe Check includes Claude Code skills that let you query your conversation history using natural language!

### Quick Start

The monitor will automatically prompt you to install skills when you first run it. You can also install manually:

```bash
./claude-skills/install-skills.sh
```

Then ask Claude:

```
"claude stats"                              # View usage statistics
"what have I been working on today?"        # See recent sessions
"search my conversations for X"             # Search history
"what tools do I use most?"                 # Analyze tool usage
```

### Available Skills

- **claude-stats** - Comprehensive usage statistics
- **search-conversations** - Full-text search across all conversations
- **analyze-tools** - Tool usage patterns and trends
- **recent-work** - Recent sessions and activity

See [claude-skills/README.md](claude-skills/README.md) for details.

## Manual Client Setup

If you prefer to install manually:

### 1. Install Dependencies

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 2. Configure

Create a `data/` directory and copy the example config:

```bash
mkdir -p data
cp config.json.example data/config.json
```

Edit `data/config.json` with your settings:

```json
{
  "api": {
    "enabled": false,
    "url": "https://your-server.com",
    "api_key": "your-api-key-here"
  },
  "sqlite": {
    "enabled": true,
    "database_path": "~/path/to/vibe-check/data/vibe_check.db",
    "user_name": "your-username"
  },
  "monitor": {
    "conversation_dir": "~/.claude/projects"
  }
}
```

**API Settings** (optional remote sync):

- `enabled` - Set to `true` to sync to a remote server
- `url` - The server endpoint URL
- `api_key` - Your API key (get from server administrator)

**SQLite Settings** (local database):

- `enabled` - Set to `true` for local database storage (recommended)
- `database_path` - Path to SQLite database file
- `user_name` - Your username for tagging events

**Monitor Settings:**

- `conversation_dir` - Directory to watch for Claude Code conversation files (default: `~/.claude/projects`)

### 3. Run

```bash
source venv/bin/activate
python vibe-check.py
```

**Skip Backlog (First Run):**

If you don't want to upload existing conversation history, use the `--skip-backlog` flag on first run:

```bash
python vibe-check.py --skip-backlog
```

This will fast-forward the state to the latest line in all conversation files without uploading them. Future runs will only monitor new conversations from that point forward.

**Skip Skills Prompt:**

If you want to skip the skills installation prompt (e.g., in automated setups):

```bash
python vibe-check.py --skip-skills-check
```

## Daemon Management

Use the unified commands for all installations:

```bash
vibe-check start     # Start in background (auto-starts on boot for Homebrew)
vibe-check stop      # Stop
vibe-check restart   # Restart
vibe-check status    # Check status
vibe-check logs      # View logs
```

For Homebrew installs, these commands automatically use `brew services` under the hood, enabling auto-start on boot.

### Manual Installation

The monitor script has built-in daemon management:

```bash
python vibe-check.py start     # Start in background
python vibe-check.py stop      # Stop
python vibe-check.py restart   # Restart
python vibe-check.py status    # Check if running
python vibe-check.py logs      # View logs (last 50 lines)
python vibe-check.py logs -n 100  # View last 100 lines
```

### Legacy Management Script

The old `manage_monitor.sh` script is still available in `scripts/` for backwards compatibility, but the built-in commands are recommended.

### How It Works

- **Process tracking**: Uses a PID file (`.monitor.pid`) to track the running process
- **Automatic restart**: Cron job checks every 15 minutes and restarts if the process has stopped
- **Logging**: Activity is logged to `~/logs/vibe_check_monitor.log`
- **Notifications**: Shows a macOS notification when the monitor is restarted
- **Monitor output**: The monitor's own output is saved to `monitor.log`
- **Skills check**: Background processes skip skills prompt (use `--skip-skills-check`)

### Viewing Logs

```bash
# View both monitoring logs and monitor output
./scripts/manage_monitor.sh logs

# Or view individually
tail -f ~/logs/vibe_check_monitor.log  # Monitoring activity
tail -f monitor.log                     # Monitor process output
```

## How It Works

1. On startup, processes any new lines in existing .jsonl files
2. Watches for file modifications/creations using OS events
3. Parses each new JSONL line as JSON
4. Sends events to API server with authentication
5. Tracks progress in SQLite database to resume after restarts
6. **Prompts to install Claude Code skills** on first interactive run

## Server Setup

See [server-php/README.md](server-php/README.md) for server installation and configuration.

## Data Locations

All installation methods use the same unified location: `~/.vibe-check/`

| File         | Path                          |
| ------------ | ----------------------------- |
| **Database** | `~/.vibe-check/vibe_check.db` |
| **Config**   | `~/.vibe-check/config.json`   |
| **PID file** | `~/.vibe-check/.monitor.pid`  |
| **Log file** | `~/.vibe-check/monitor.log`   |

When running via Homebrew service (`brew services start vibe-check`), logs go to:

- `/opt/homebrew/var/log/vibe-check.log` (unified stdout + stderr)

**Log rotation:** Daemon mode logs auto-rotate at 5 MB, keeping 3 backup files.

**Note:** Homebrew installations symlink `/opt/homebrew/var/vibe-check` → `~/.vibe-check` for compatibility.

### Querying Database Location

```bash
# Check your config
cat ~/.vibe-check/config.json | grep database_path
```

## Files

- `vibe-check.py` - Main monitoring client script
- `scripts/manage_monitor.sh` - Management script for starting/stopping monitor and installing cron job
- `config.json` - API credentials and settings
- `.monitor.pid` - Auto-generated PID file (tracks running monitor process)
- `monitor.log` - Auto-generated output log from monitor process
- `requirements.txt` - Python dependencies
- `vibe_check.db` - Local SQLite database (stores conversation data and file processing state)
- `claude-skills/` - Claude Code skills for querying your usage
- `server-php/` - API server code (PHP)
- `~/Scripts/monitor_vibe_check.sh` - Cron script that checks if monitor is running

## Querying the Data

### Using Claude Code Skills (Recommended)

The easiest way to explore your data is using the included Claude Code skills:

```bash
# Install skills
./claude-skills/install-skills.sh

# Then ask Claude in natural language:
# "claude stats"
# "what have I been working on?"
# "search my conversations for authentication"
```

See [claude-skills/README.md](claude-skills/README.md) for full documentation.

### Direct SQLite Queries

Query your local database directly:

```bash
# Using the helper script (handles read-only mode)
./scripts/query-helper.sh ~/Developer/vibe-check/vibe_check.db "SELECT COUNT(*) FROM conversation_events"

# Or use sqlite3 directly
sqlite3 "file:~/Developer/vibe-check/vibe_check.db?mode=ro" "SELECT * FROM conversation_events LIMIT 10"
```

See [SKILLS-README.md](SKILLS-README.md) for schema details and example queries.

### MySQL Server Queries

Connect to the MySQL server and run queries:

```sql
-- Count events per file
SELECT file_name, COUNT(*) as event_count
FROM conversation_events
GROUP BY file_name;

-- Count events per user
SELECT user_name, COUNT(*) as event_count
FROM conversation_events
GROUP BY user_name;

-- View recent events
SELECT file_name, line_number, user_name, inserted_at
FROM conversation_events
ORDER BY inserted_at DESC
LIMIT 10;

-- Search within JSON (requires MySQL 5.7+)
SELECT file_name, line_number, event_data
FROM conversation_events
WHERE JSON_EXTRACT(event_data, '$.type') = 'message';
```

Or use the API:

```bash
curl -H "X-API-Key: your-api-key" https://vibecheck.wanderingstan.com/events?limit=10
```

## Notes

- Client-server architecture for better security (no direct DB access from clients)
- API key authentication for access control
- State file ensures idempotency across restarts
- Handles malformed JSON gracefully (logs and continues)
- Server uses MySQL native JSON type for efficient storage
- **Skills prompt only appears on interactive runs** (skipped for background/cron jobs)
