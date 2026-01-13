# SQLite Local Database Setup

This document explains how to use local SQLite recording for the Vibe Check monitor.

## Overview

By default, the monitor sends events to a remote API server. With SQLite integration, you can also store events in a local SQLite database for faster queries, offline access, and local analysis.

## Features

- **Dual Recording**: Events are recorded to both the API server and local SQLite (if enabled)
- **Resilient**: If one destination fails, the other continues to work
- **Optional**: SQLite is completely optional - the monitor works fine without it
- **Zero Setup**: No server installation required - SQLite is built into Python
- **File-Based**: Database is just a file on disk
- **Automatic Schema**: Tables and indexes are created automatically

## Setup Instructions

### 0. Migration Note (If You Have Existing Data)

If you already have a database with the old schema, you'll need to either:

1. Delete the old database file and let it recreate with the new schema
2. Or manually migrate the data (see Migration section below)

### 1. Enable SQLite in Configuration

Edit [config.json](config.json) and configure the SQLite section:

```json
{
  "sqlite": {
    "enabled": true,
    "database_path": "~/Developer/vibe-check/vibe_check.db",
    "user_name": "your_username"
  }
}
```

The database file will be created automatically when the monitor starts.

### 2. Restart the Monitor

```bash
./manage_monitor.sh restart
```

That's it! No server installation, no credentials needed.

## Database Schema

The database contains one main table that is automatically created. The schema matches the MySQL server schema for consistency.

### `conversation_events` Table

| Column            | Type     | Description                                                        |
| ----------------- | -------- | ------------------------------------------------------------------ |
| id                | INTEGER  | Auto-incrementing primary key                                      |
| file_name         | TEXT     | Relative path to the conversation file                             |
| line_number       | INTEGER  | Line number in the file                                            |
| event_data        | TEXT     | Full event data as JSON                                            |
| user_name         | TEXT     | Username from configuration                                        |
| inserted_at       | DATETIME | When the event was recorded (database time)                        |
| event_type        | TEXT     | Generated: Event type (e.g., "user", "assistant")                  |
| event_message     | TEXT     | Generated: Message text content (NULL if not a message event)      |
| event_git_branch  | TEXT     | Generated: Git branch name                                         |
| event_session_id  | TEXT     | Generated: Claude Code session ID                                  |
| event_uuid        | TEXT     | Generated: Event UUID                                              |
| event_timestamp   | TEXT     | Generated: Event timestamp from the event data                     |

**Indexes:**

- `idx_file_name` - For fast file lookups
- `idx_user_name` - For filtering by user
- `idx_inserted_at` - For time-based queries
- `idx_event_type` - For filtering by event type
- `idx_event_message` - For filtering messages (partial index)
- `idx_event_git_branch` - For filtering by git branch
- `idx_event_session_id` - For filtering by session
- `idx_event_uuid` - For filtering by UUID
- Unique constraint on `(file_name, line_number)` to prevent duplicates

**Note:** Generated columns are STORED (not virtual), meaning they're computed once on insert and physically stored for fast queries.

## Usage

### View Recent Events with sqlite3 CLI

```bash
sqlite3 ~/Developer/vibe-check/vibe_check.db "SELECT * FROM conversation_events ORDER BY inserted_at DESC LIMIT 10;"
```

### Count Events by File

```bash
sqlite3 ~/Developer/vibe-check/vibe_check.db "
SELECT file_name, COUNT(*) as event_count
FROM conversation_events
GROUP BY file_name
ORDER BY event_count DESC
LIMIT 10;
"
```

### Query Event Data (JSON)

```bash
sqlite3 ~/Developer/vibe-check/vibe_check.db "
SELECT
  file_name,
  event_type,
  user_name,
  inserted_at
FROM conversation_events
LIMIT 10;
"
```

### Query Messages Only

```bash
sqlite3 ~/Developer/vibe-check/vibe_check.db "
SELECT
  user_name,
  event_type,
  event_message,
  event_git_branch,
  inserted_at
FROM conversation_events
WHERE event_message IS NOT NULL
ORDER BY inserted_at DESC
LIMIT 20;
"
```

### Query by Git Branch

```bash
sqlite3 ~/Developer/vibe-check/vibe_check.db "
SELECT
  event_git_branch,
  COUNT(*) as event_count,
  COUNT(event_message) as message_count
FROM conversation_events
WHERE event_git_branch IS NOT NULL
GROUP BY event_git_branch
ORDER BY event_count DESC
LIMIT 10;
"
```

### Query by Session

```bash
sqlite3 ~/Developer/vibe-check/vibe_check.db "
SELECT
  event_session_id,
  COUNT(*) as event_count,
  MIN(inserted_at) as session_start,
  MAX(inserted_at) as session_end
FROM conversation_events
WHERE event_session_id IS NOT NULL
GROUP BY event_session_id
ORDER BY session_start DESC
LIMIT 10;
"
```

### Using Python to Query

```python
import sqlite3
from pathlib import Path

db_path = Path('~/Developer/vibe-check/vibe_check.db').expanduser()
conn = sqlite3.connect(str(db_path))
cursor = conn.cursor()

# Get recent messages with branch info
cursor.execute("""
    SELECT user_name, event_type, event_message, event_git_branch, inserted_at
    FROM conversation_events
    WHERE event_message IS NOT NULL
    ORDER BY inserted_at DESC
    LIMIT 10
""")

for row in cursor.fetchall():
    user_name, event_type, message, branch, inserted_at = row
    branch_info = f" [{branch}]" if branch else ""
    print(f"{inserted_at} [@{user_name}]{branch_info} {event_type}: {message[:100]}")

conn.close()
```

## Monitoring

Check the monitor logs to see SQLite status:

```bash
./manage_monitor.sh logs
```

You should see messages like:

- `Connected to SQLite database: /path/to/vibe_check.db`
- `Inserted: filename.jsonl:123 → API, SQLite`

## Troubleshooting

### Database File Not Found

The database file is created automatically when the monitor starts. If you don't see it, check:

1. The path in [config.json](config.json) is writable
2. The monitor is running: `./manage_monitor.sh status`
3. The logs for any errors: `./manage_monitor.sh logs`

### SQLite Errors

If you see SQLite errors in the logs, the monitor will continue to work and send events to the API. Common issues:

- **Disk full**: Free up space on your disk
- **Permission denied**: Check file permissions on the database directory
- **Database locked**: Another process is accessing the database

### Database File is Large

SQLite databases can grow over time. To compact the database:

```bash
sqlite3 ~/Developer/vibe-check/vibe_check.db "VACUUM;"
```

To delete old events (older than 30 days):

```bash
sqlite3 ~/Developer/vibe-check/vibe_check.db "
DELETE FROM conversation_events
WHERE inserted_at < datetime('now', '-30 days');
VACUUM;
"
```

## Disabling SQLite

To disable SQLite recording:

1. Edit [config.json](config.json)
2. Set `"enabled": false` in the sqlite section
3. Restart the monitor: `./manage_monitor.sh restart`

## Performance

- SQLite recording is very fast (< 1ms per insert)
- Events are committed immediately (no batching)
- Duplicate events are automatically ignored
- The database is thread-safe with `check_same_thread=False`

## Backup

To backup your events:

```bash
# Simple file copy (stop monitor first)
./manage_monitor.sh stop
cp ~/Developer/vibe-check/vibe_check.db ~/Developer/vibe-check/vibe_check_backup.db
./manage_monitor.sh start

# Or use SQLite backup command (can run while monitor is running)
sqlite3 ~/Developer/vibe-check/vibe_check.db ".backup ~/Developer/vibe-check/vibe_check_backup.db"
```

To restore from backup:

```bash
./manage_monitor.sh stop
cp ~/Developer/vibe-check/vibe_check_backup.db ~/Developer/vibe-check/vibe_check.db
./manage_monitor.sh start
```

## Advanced Usage

### Export to CSV

```bash
sqlite3 -header -csv ~/Developer/vibe-check/vibe_check.db "SELECT * FROM conversation_events;" > events.csv
```

### Export to JSON

```bash
sqlite3 ~/Developer/vibe-check/vibe_check.db "SELECT json_group_array(json_object(
  'id', id,
  'file_name', file_name,
  'line_number', line_number,
  'user_name', user_name,
  'inserted_at', inserted_at,
  'event_type', event_type,
  'event_message', event_message,
  'event_git_branch', event_git_branch,
  'event_session_id', event_session_id,
  'event_uuid', event_uuid
)) FROM conversation_events;" > events.json
```

### Using with DB Browser for SQLite

For a GUI interface, download [DB Browser for SQLite](https://sqlitebrowser.org/) and open the database file.

## Database Location

The default database location is `~/Developer/vibe-check/vibe_check.db` but you can change it in [config.json](config.json):

```json
{
  "sqlite": {
    "enabled": true,
    "database_path": "/custom/path/to/database.db"
  }
}
```

Paths starting with `~/` are automatically expanded to your home directory.

## Security Notes

- The database file is stored locally with filesystem permissions
- Anyone with read access to the file can read the events
- The database is not encrypted by default
- For sensitive data, consider encrypting the filesystem or using an encrypted disk image

## Migrating from Old Schema

If you have an existing database with an older schema, use the migration script:

```bash
# IMPORTANT: Stop the monitor first (otherwise database will be locked)
./manage_monitor.sh stop

# Backup your database
cp ~/Developer/vibe-check/vibe_check.db ~/Developer/vibe-check/vibe_check_backup_$(date +%Y%m%d).db

# Run the migration script
sqlite3 ~/Developer/vibe-check/vibe_check.db < migrate_sqlite.sql

# Restart the monitor
./manage_monitor.sh start
```

The migration script ([migrate_sqlite.sql](migrate_sqlite.sql)) will:
- Create a new table with the updated schema
- Copy all existing data (generated columns are auto-computed)
- Drop the old table and rename the new one
- Recreate all indexes
- Display verification statistics

Or simply delete the old database and start fresh:

```bash
rm ~/Developer/vibe-check/vibe_check.db
./manage_monitor.sh restart
```

## Advantages Over MySQL

- **No server required**: SQLite is serverless and file-based
- **Zero configuration**: No credentials, ports, or networking
- **Simpler backup**: Just copy the database file
- **Built into Python**: No additional dependencies
- **Perfect for single-user scenarios**: Great for local development and analysis

## When to Use MySQL Instead

Consider MySQL if you need:

- Multiple concurrent writers from different machines
- Network access to the database
- Advanced user permissions and access control
- Very large datasets (> 100GB)
