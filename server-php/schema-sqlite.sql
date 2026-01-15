-- SQLite schema for Vibe Check server

-- Conversation events table
CREATE TABLE IF NOT EXISTS conversation_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_name TEXT NOT NULL,
    line_number INTEGER NOT NULL,
    event_data TEXT NOT NULL,
    user_name TEXT NOT NULL,
    inserted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    -- Generated columns for efficient querying
    event_type TEXT GENERATED ALWAYS AS
        (json_extract(event_data, '$.type')) STORED,
    event_message TEXT GENERATED ALWAYS AS
        (json_extract(event_data, '$.message.content[0].text')) STORED,
    event_git_branch TEXT GENERATED ALWAYS AS
        (json_extract(event_data, '$.gitBranch')) STORED,
    event_session_id TEXT GENERATED ALWAYS AS
        (json_extract(event_data, '$.sessionId')) STORED,
    event_uuid TEXT GENERATED ALWAYS AS
        (json_extract(event_data, '$.uuid')) STORED,
    event_timestamp TEXT GENERATED ALWAYS AS
        (json_extract(event_data, '$.timestamp')) STORED,
    git_remote_url TEXT,
    git_commit_hash TEXT,
    UNIQUE(file_name, line_number)
);

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_file_name ON conversation_events(file_name);
CREATE INDEX IF NOT EXISTS idx_user_name ON conversation_events(user_name);
CREATE INDEX IF NOT EXISTS idx_inserted_at ON conversation_events(inserted_at);
CREATE INDEX IF NOT EXISTS idx_event_type ON conversation_events(event_type);
CREATE INDEX IF NOT EXISTS idx_event_message ON conversation_events(event_message);
CREATE INDEX IF NOT EXISTS idx_event_git_branch ON conversation_events(event_git_branch);
CREATE INDEX IF NOT EXISTS idx_event_session_id ON conversation_events(event_session_id);
CREATE INDEX IF NOT EXISTS idx_event_uuid ON conversation_events(event_uuid);
CREATE INDEX IF NOT EXISTS idx_git_remote_url ON conversation_events(git_remote_url);
CREATE INDEX IF NOT EXISTS idx_git_commit_hash ON conversation_events(git_commit_hash);

-- API Keys table for authentication
CREATE TABLE IF NOT EXISTS api_keys (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_name TEXT NOT NULL UNIQUE,
    api_key TEXT NOT NULL UNIQUE,
    is_active INTEGER DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_used_at DATETIME
);

CREATE INDEX IF NOT EXISTS idx_api_key ON api_keys(api_key);
CREATE INDEX IF NOT EXISTS idx_active ON api_keys(is_active);

-- Example: Insert a test user (change the API key!)
-- First generate a key: python3 -c "import secrets; print(secrets.token_urlsafe(32))"
-- Then run: INSERT INTO api_keys (user_name, api_key) VALUES ('stan', 'your-generated-key-here');
