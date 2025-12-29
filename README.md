# Claude Code Conversation Monitor

Monitors Claude Code conversation files and stores events in MySQL for later analysis.

## Features

- Real-time monitoring using watchdog (OS-level file events)
- Incremental processing (only new lines, no reprocessing)
- State persistence (resumes after restart)
- Duplicate prevention (UNIQUE constraint on file+line)
- JSON blob storage (flexible for future schema changes)

## Setup

### 1. Install Dependencies

```bash
pip install -r requirements.txt
```

### 2. Set Up MySQL Database

```bash
mysql -u root -p < schema.sql
```

Or manually:
```sql
CREATE DATABASE claude_conversations;
-- Then run the contents of schema.sql
```

### 3. Configure

Edit `config.json` with your MySQL credentials:

```json
{
  "mysql": {
    "host": "localhost",
    "port": 3306,
    "user": "your_username",
    "password": "your_password",
    "database": "claude_conversations"
  }
}
```

### 4. Run

```bash
python monitor.py
```

## How It Works

1. On startup, processes any new lines in existing .jsonl files
2. Watches for file modifications/creations using OS events
3. Parses each new JSONL line as JSON
4. Inserts into MySQL with file name and line number
5. Tracks progress in `state.json` to resume after restarts

## Files

- `monitor.py` - Main monitoring script
- `config.json` - Database credentials and settings
- `schema.sql` - Database schema
- `state.json` - Auto-generated state tracking (last processed line per file)
- `requirements.txt` - Python dependencies

## Querying the Data

Example queries:

```sql
-- Count events per file
SELECT file_name, COUNT(*) as event_count
FROM conversation_events
GROUP BY file_name;

-- View recent events
SELECT file_name, line_number, event_data, inserted_at
FROM conversation_events
ORDER BY inserted_at DESC
LIMIT 10;

-- Search within JSON (requires MySQL 5.7+)
SELECT file_name, line_number, event_data
FROM conversation_events
WHERE JSON_EXTRACT(event_data, '$.type') = 'message';
```

## Notes

- Uses MySQL native JSON type for efficient storage
- UNIQUE constraint prevents duplicate inserts
- State file ensures idempotency across restarts
- Handles malformed JSON gracefully (logs and continues)
