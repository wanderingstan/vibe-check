# Vibe-Check Claude Code Conversation Monitor

Monitors Claude Code conversation files and sends events to the Vibe Check API server for storage.

## Quick Install

The easiest way to get started:

```bash
curl -fsSL https://vibecheck.wanderingstan.com/install.sh | bash
```

This will:

- Install Vibe Check to `~/.vibe-check`
- Create your user account and API key
- Set up the configuration
- Start monitoring your Claude Code conversations

## Updating

To update to the latest version, simply run the install command again:

```bash
curl -fsSL https://vibecheck.wanderingstan.com/install.sh | bash
```

This will update the code and dependencies while preserving your configuration.

## Uninstalling

To uninstall Vibe Check:

```bash
~/.vibe-check/uninstall.sh
```

This will remove the installation directory and stop any running monitor processes. Your server account will remain active.

## Architecture

- **Client (monitor.py)**: Watches local .jsonl files and sends events to API
- **Server (server-php/)**: PHP API that authenticates requests and stores in MySQL

## Features

- Real-time monitoring using watchdog (OS-level file events)
- Incremental processing (only new lines, no reprocessing)
- State persistence (resumes after restart)
- API key authentication
- JSON blob storage (flexible for future schema changes)

## Manual Client Setup

If you prefer to install manually:

### 1. Install Dependencies

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 2. Configure

Edit `config.json` with your API details and monitoring settings:

```json
{
  "api": {
    "url": "https://vibecheck.wanderingstan.com",
    "api_key": "your-api-key-here"
  },
  "monitor": {
    "conversation_dir": "~/.claude/projects",
    "state_file": "state.json",
    "debug_filter_project": "-Users-yourname-Developer-vibe-check"
  }
}
```

**API Settings:**

- `url` - The server endpoint URL
- `api_key` - Your API key (get from server administrator)

**Monitor Settings:**

- `conversation_dir` - Directory to watch for Claude Code conversation files (default: `~/.claude/projects`)
- `state_file` - File to store processing state (default: `state.json`)
- `debug_filter_project` - (Optional) Project path to montior exclusively, useful when testing.

### 3. Run

```bash
source venv/bin/activate
python monitor.py
```

**Skip Backlog (First Run):**

If you don't want to upload existing conversation history, use the `--skip-backlog` flag on first run:

```bash
python monitor.py --skip-backlog
```

This will fast-forward the state to the latest line in all conversation files without uploading them. Future runs will only monitor new conversations from that point forward.

## Keeping the Monitor Running

To ensure the monitor stays running continuously, you can use the included monitoring scripts:

### Management Script

The `manage_monitor.sh` script provides easy control over the monitor process:

```bash
./manage_monitor.sh start         # Start the monitor
./manage_monitor.sh stop          # Stop the monitor
./manage_monitor.sh restart       # Restart the monitor
./manage_monitor.sh status        # Check if monitor is running
./manage_monitor.sh logs          # View recent logs
./manage_monitor.sh install-cron  # Install automatic checking (every 15 min)
./manage_monitor.sh uninstall-cron # Remove automatic checking
```

### Automatic Monitoring with Cron

To have the system automatically restart the monitor if it stops:

1. Install the cron job:
```bash
./manage_monitor.sh install-cron
```

This will check every 15 minutes if the monitor is running and restart it if needed.

### How It Works

- **Process tracking**: Uses a PID file (`.monitor.pid`) to track the running process
- **Automatic restart**: Cron job checks every 15 minutes and restarts if the process has stopped
- **Logging**: Activity is logged to `~/logs/vibe_check_monitor.log`
- **Notifications**: Shows a macOS notification when the monitor is restarted
- **Monitor output**: The monitor's own output is saved to `monitor.log`

### Viewing Logs

```bash
# View both monitoring logs and monitor output
./manage_monitor.sh logs

# Or view individually
tail -f ~/logs/vibe_check_monitor.log  # Monitoring activity
tail -f monitor.log                     # Monitor process output
```

## How It Works

1. On startup, processes any new lines in existing .jsonl files
2. Watches for file modifications/creations using OS events
3. Parses each new JSONL line as JSON
4. Sends events to API server with authentication
5. Tracks progress in `state.json` to resume after restarts

## Server Setup

See [server-php/README.md](server-php/README.md) for server installation and configuration.

## Files

- `monitor.py` - Main monitoring client script
- `manage_monitor.sh` - Management script for starting/stopping monitor and installing cron job
- `config.json` - API credentials and settings
- `state.json` - Auto-generated state tracking (last processed line per file)
- `.monitor.pid` - Auto-generated PID file (tracks running monitor process)
- `monitor.log` - Auto-generated output log from monitor process
- `requirements.txt` - Python dependencies
- `server-php/` - API server code (PHP)
- `~/Scripts/monitor_vibe_check.sh` - Cron script that checks if monitor is running

## Querying the Data

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
