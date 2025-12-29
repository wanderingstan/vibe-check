# Vibe Check API Server

Simple Flask API server for receiving conversation events from monitors.

## Setup

### 1. Install Dependencies

```bash
cd server
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 2. Configure Database

Edit `config.json` with your MySQL credentials.

### 3. Create API Keys Table

```bash
mysql -h wanderingstan.com -u wanderin_vibecheck_admin -p wanderin_vibecheck < schema.sql
```

Or run via phpMyAdmin.

### 4. Create an API Key

Generate a secure random key:
```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Insert it into MySQL:
```sql
INSERT INTO api_keys (user_name, api_key)
VALUES ('stan', 'YOUR-GENERATED-KEY-HERE');
```

## Running

### Development
```bash
source venv/bin/activate
python app.py
```

Server runs on http://0.0.0.0:5000

### Production (with Gunicorn)
```bash
pip install gunicorn
gunicorn -w 4 -b 0.0.0.0:5000 app:app
```

## API Endpoints

### POST /events
Insert a new conversation event.

**Headers:**
- `X-API-Key`: Your API key
- `Content-Type`: application/json

**Body:**
```json
{
  "file_name": "project/conversation.jsonl",
  "line_number": 123,
  "event_data": {...}
}
```

**Response:**
```json
{
  "status": "ok",
  "file_name": "project/conversation.jsonl",
  "line_number": 123
}
```

### GET /events?limit=10
List recent events (for debugging).

**Headers:**
- `X-API-Key`: Your API key

### GET /health
Health check (no auth required).

## Security Notes

- API keys are passed in headers (more secure than URL params)
- Use HTTPS in production
- Store `config.json` safely (contains DB password)
- Rotate API keys periodically
