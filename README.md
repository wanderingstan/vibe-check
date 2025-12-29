# Claude Code Conversation Monitor

Monitors Claude Code conversation files and sends events to the Vibe Check API server for storage.

## Architecture

- **Client (monitor.py)**: Watches local .jsonl files and sends events to API
- **Server (server-php/)**: PHP API that authenticates requests and stores in MySQL

## Features

- Real-time monitoring using watchdog (OS-level file events)
- Incremental processing (only new lines, no reprocessing)
- State persistence (resumes after restart)
- API key authentication
- JSON blob storage (flexible for future schema changes)

## Client Setup

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
- `config.json` - API credentials and settings
- `state.json` - Auto-generated state tracking (last processed line per file)
- `requirements.txt` - Python dependencies
- `server-php/` - API server code (PHP)

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
