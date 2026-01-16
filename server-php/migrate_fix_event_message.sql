-- Migration to fix event_message generated column to handle both array and string formats
-- SQLite version

BEGIN TRANSACTION;

-- Create new table with fixed schema
CREATE TABLE conversation_events_new (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_name TEXT NOT NULL,
    line_number INTEGER NOT NULL,
    event_data TEXT NOT NULL,
    user_name TEXT NOT NULL,
    inserted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    event_type TEXT GENERATED ALWAYS AS
        (json_extract(event_data, '$.type')) STORED,
    event_message TEXT GENERATED ALWAYS AS
        (CASE
            WHEN substr(json_extract(event_data, '$.message.content'), 1, 1) = '['
            THEN json_extract(event_data, '$.message.content[0].text')
            ELSE json_extract(event_data, '$.message.content')
        END) STORED,
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

-- Copy all data from old table to new table
INSERT INTO conversation_events_new
    (id, file_name, line_number, event_data, user_name, inserted_at, git_remote_url, git_commit_hash)
SELECT
    id, file_name, line_number, event_data, user_name, inserted_at, git_remote_url, git_commit_hash
FROM conversation_events;

-- Drop old table
DROP TABLE conversation_events;

-- Rename new table to original name
ALTER TABLE conversation_events_new RENAME TO conversation_events;

-- Recreate indexes
CREATE INDEX idx_file_name ON conversation_events(file_name);
CREATE INDEX idx_user_name ON conversation_events(user_name);
CREATE INDEX idx_inserted_at ON conversation_events(inserted_at);
CREATE INDEX idx_event_type ON conversation_events(event_type);
CREATE INDEX idx_event_message ON conversation_events(event_message);
CREATE INDEX idx_event_git_branch ON conversation_events(event_git_branch);
CREATE INDEX idx_event_session_id ON conversation_events(event_session_id);
CREATE INDEX idx_event_uuid ON conversation_events(event_uuid);
CREATE INDEX idx_git_remote_url ON conversation_events(git_remote_url);
CREATE INDEX idx_git_commit_hash ON conversation_events(git_commit_hash);

COMMIT;
