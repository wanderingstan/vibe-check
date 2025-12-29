# Quick Setup Guide

## Overview

The system has two parts:
1. **Server** (runs on Hostgator): Flask API + MySQL database
2. **Client** (runs on your Mac): Monitors .jsonl files and sends to server

## Server Setup (on Hostgator)

### 1. Upload Server Code

Upload the `server/` directory to your Hostgator account.

### 2. Create Database Tables

Run the schema file via phpMyAdmin:

1. Go to phpMyAdmin → `wanderin_vibecheck` database
2. Click "SQL" tab
3. Paste contents of [server/schema.sql](server/schema.sql)
4. Click "Go"

This creates both the `conversation_events` and `api_keys` tables.

### 3. Generate and Store API Key

```bash
# Generate a secure key locally
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Then in phpMyAdmin, run:
```sql
INSERT INTO api_keys (user_name, api_key)
VALUES ('stan', 'paste-your-generated-key-here');
```

Save this key! You'll need it for the client.

### 4. Configure Server

Edit `server/config.json` on Hostgator:
```json
{
  "mysql": {
    "host": "localhost",
    "port": 3306,
    "user": "wanderin_vibecheck_admin",
    "password": "your-db-password",
    "database": "wanderin_vibecheck"
  },
  "server": {
    "host": "0.0.0.0",
    "port": 5000
  }
}
```

### 5. Install Dependencies & Run

```bash
cd server
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Test it
python app.py
```

For production, use Gunicorn or set up via cPanel Python app.

## Client Setup (on your Mac)

### 1. Install Dependencies

```bash
cd /Users/wanderingstan/Developer/vibe-check
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 2. Configure Client

Edit `config.json`:
```json
{
  "api": {
    "url": "http://wanderingstan.com:5000",
    "api_key": "your-api-key-from-server"
  },
  "monitor": {
    "conversation_dir": "~/.claude/projects",
    "state_file": "state.json",
    "debug_filter_project": "-Users-wanderingstan-Developer-vibe-check"
  }
}
```

### 3. Run Monitor

```bash
source venv/bin/activate
python monitor.py
```

Or use VS Code debugger (F5).

## Testing

### Test Server

```bash
# Health check (no auth)
curl http://wanderingstan.com:5000/health

# List events (with auth)
curl -H "X-API-Key: your-api-key" http://wanderingstan.com:5000/events?limit=5
```

### Test Client

Just run the monitor and make changes in Claude Code. You should see:
```
Connected to API server: http://wanderingstan.com:5000
Processing 1 new line(s) from -Users-wanderingstan-Developer-vibe-check/conversation.jsonl
  Inserted: -Users-wanderingstan-Developer-vibe-check/conversation.jsonl:123
```

## Troubleshooting

**Connection refused**:
- Check if server is running
- Check firewall/port settings on Hostgator
- Verify URL in client config

**401 Unauthorized**:
- Check API key matches between client and database
- Verify api_keys table has active key

**Database errors**:
- Check MySQL credentials in server/config.json
- Verify tables exist (run schema files)
