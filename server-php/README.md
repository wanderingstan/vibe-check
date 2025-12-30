# Vibe Check API - PHP Edition

Simple PHP API for basic shared hosting (no Python app support needed).

## Important: Database Migration

If you already created the `conversation_events` table before, you need to add the `user_name` column:

**Run this in phpMyAdmin:**
```sql
ALTER TABLE conversation_events
ADD COLUMN user_name VARCHAR(100) NOT NULL DEFAULT 'unknown' AFTER event_data;

ADD INDEX idx_user_name (user_name);
```

Or use the provided [migration_add_user_name.sql](migration_add_user_name.sql) file.

## Installation

### 1. Upload Files

Upload these files to your Hostgator account:
```
~/public_html/vibecheck/
├── api.php
├── config.json
└── .htaccess
```

Or to a subdomain:
```
~/vibecheck.wanderingstan.com/
├── api.php
├── config.json
└── .htaccess
```

### 2. Configure

Edit `config.json` with your MySQL credentials:
```json
{
  "mysql": {
    "host": "localhost",
    "user": "wanderin_vibecheck_admin",
    "password": "your-password",
    "database": "wanderin_vibecheck"
  }
}
```

### 3. Setup Database

Run the schema in phpMyAdmin (from `server/schema.sql`):
- Creates `conversation_events` table
- Creates `api_keys` table

### 4. Generate API Key

**Option A: Use the API endpoint (Recommended)**
```bash
curl -X POST https://wanderingstan.com/vibecheck/create-token \
  -H "Content-Type: application/json" \
  -d '{"username": "your-username"}'
```

This will return your API key. Save it securely!

**Option B: Manual creation via phpMyAdmin**

Generate a key locally:
```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Insert in phpMyAdmin:
```sql
INSERT INTO api_keys (user_name, api_key)
VALUES ('stan', 'your-generated-key-here');
```

## API Endpoints

### GET /health
Health check (no auth required)

```bash
curl https://wanderingstan.com/vibecheck/health
```

### POST /create-token
Create a new user and API token (no auth required)

**Request:**
```bash
curl -X POST https://wanderingstan.com/vibecheck/create-token \
  -H "Content-Type: application/json" \
  -d '{"username": "your-username"}'
```

**Success Response (201):**
```json
{
  "status": "ok",
  "username": "your-username",
  "api_key": "SecureRandomGeneratedKey...",
  "message": "API token created successfully"
}
```

**Error Responses:**
- `400` - Missing/empty username or too long (max 100 chars)
- `409` - Username already exists
- `500` - Database error

### POST /events
Insert event (requires API key)

```bash
curl -X POST https://wanderingstan.com/vibecheck/events \
  -H "X-API-Key: your-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "file_name": "test.jsonl",
    "line_number": 1,
    "event_data": {"test": "data"}
  }'
```

### GET /events?limit=10
List recent events (requires API key)

```bash
curl -H "X-API-Key: your-api-key" \
  https://wanderingstan.com/vibecheck/events?limit=5
```

## URL Structure

With `.htaccess` enabled, you can use clean URLs:
- `https://wanderingstan.com/vibecheck/health`
- `https://wanderingstan.com/vibecheck/events`

Without `.htaccess`:
- `https://wanderingstan.com/vibecheck/api.php/health`
- `https://wanderingstan.com/vibecheck/api.php/events`

## Client Installation

### Quick Install (Recommended)

Users can install the Vibe Check client with a single command:

```bash
curl -fsSL https://vibecheck.wanderingstan.com/install.sh | bash
```

This automated installer will:
1. Clone the repository to `~/.vibe-check`
2. Set up Python virtual environment
3. Ask for a username and automatically register it via the `/create-token` API
4. Create `config.json` with the generated API key
5. Optionally start monitoring immediately

### Manual Configuration

Update your client `config.json`:
```json
{
  "api": {
    "url": "https://wanderingstan.com/vibecheck",
    "api_key": "your-api-key-here"
  }
}
```

## Troubleshooting

### 500 Internal Server Error
- Check file permissions (644 for .php and .json, 755 for directories)
- Check PHP error logs
- Verify database credentials in config.json

### 404 Not Found
- Ensure .htaccess is uploaded
- Verify mod_rewrite is enabled (usually is on Hostgator)
- Try accessing directly: `/api.php/health`

### Connection refused
- Verify MySQL credentials
- Check if MySQL hostname is `localhost` (try `127.0.0.1` if localhost fails)
- Ensure remote MySQL access is enabled if needed

## Security Notes

- Keep `config.json` outside public_html if possible
- Use HTTPS in production
- Rotate API keys periodically
- Monitor `api_keys.last_used_at` for suspicious activity
