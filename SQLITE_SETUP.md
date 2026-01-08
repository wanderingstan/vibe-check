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

### 1. Enable SQLite in Configuration

Edit [config.json](config.json) and configure the SQLite section:

```json
{
  "sqlite": {
    "enabled": true,
    "database_path": "~/Developer/vibe-check/vibe_check.db"
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

The database contains one main table that is automatically created:

### `events` Table

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Auto-incrementing primary key |
| file_name | TEXT | Relative path to the conversation file |
| line_number | INTEGER | Line number in the file |
| event_data | TEXT | Full event data as JSON |
| timestamp | DATETIME | When the event was recorded (database time) |

**Indexes:**
- `idx_file_name` - For fast file lookups
- `idx_timestamp` - For time-based queries
- Unique constraint on `(file_name, line_number)` to prevent duplicates

## Usage

### View Recent Events with sqlite3 CLI

```bash
sqlite3 ~/Developer/vibe-check/vibe_check.db "SELECT * FROM events ORDER BY timestamp DESC LIMIT 10;"
```

### Count Events by File

```bash
sqlite3 ~/Developer/vibe-check/vibe_check.db "
SELECT file_name, COUNT(*) as event_count
FROM events
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
  json_extract(event_data, '$.type') AS type,
  substr(event_data, 1, 100) AS content_preview
FROM events
LIMIT 10;
"
```

### Using Python to Query

```python
import sqlite3
import json

conn = sqlite3.connect('~/Developer/vibe-check/vibe_check.db')
cursor = conn.cursor()

# Get recent events
cursor.execute("SELECT * FROM events ORDER BY timestamp DESC LIMIT 10")
for row in cursor.fetchall():
    event_id, file_name, line_number, event_data, timestamp = row
    event = json.loads(event_data)
    print(f"{timestamp}: {file_name}:{line_number} - {event.get('type')}")

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
DELETE FROM events
WHERE timestamp < datetime('now', '-30 days');
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
sqlite3 -header -csv ~/Developer/vibe-check/vibe_check.db "SELECT * FROM events;" > events.csv
```

### Export to JSON

```bash
sqlite3 ~/Developer/vibe-check/vibe_check.db "SELECT json_group_array(json_object(
  'id', id,
  'file_name', file_name,
  'line_number', line_number,
  'event_data', json(event_data),
  'timestamp', timestamp
)) FROM events;" > events.json
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
