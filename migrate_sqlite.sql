-- SQLite Migration Script
-- Migrates conversation_events table to new schema with updated generated columns
--
-- IMPORTANT STEPS BEFORE RUNNING:
-- 1. Stop the monitor (otherwise database will be locked):
--    ./manage_monitor.sh stop
--
-- 2. Backup your database:
--    cp ~/Developer/vibe-check/vibe_check.db ~/Developer/vibe-check/vibe_check_backup.db
--
-- 3. Run this migration:
--    sqlite3 ~/Developer/vibe-check/vibe_check.db < migrate_sqlite.sql
--
-- 4. Restart the monitor:
--    ./manage_monitor.sh start

BEGIN TRANSACTION;

-- Create new table with updated schema
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
        (json_extract(event_data, '$.message.content[0].text')) STORED,
    event_git_branch TEXT GENERATED ALWAYS AS
        (json_extract(event_data, '$.gitBranch')) STORED,
    event_session_id TEXT GENERATED ALWAYS AS
        (json_extract(event_data, '$.sessionId')) STORED,
    event_uuid TEXT GENERATED ALWAYS AS
        (json_extract(event_data, '$.uuid')) STORED,
    event_timestamp TEXT GENERATED ALWAYS AS
        (json_extract(event_data, '$.timestamp')) STORED,
    UNIQUE(file_name, line_number)
);

-- Copy all data from old table
-- Generated columns will be automatically computed
INSERT INTO conversation_events_new
    (id, file_name, line_number, event_data, user_name, inserted_at)
SELECT
    id, file_name, line_number, event_data, user_name, inserted_at
FROM conversation_events;

-- Drop old table
DROP TABLE conversation_events;

-- Rename new table
ALTER TABLE conversation_events_new RENAME TO conversation_events;

-- Create indexes
CREATE INDEX idx_file_name ON conversation_events(file_name);
CREATE INDEX idx_user_name ON conversation_events(user_name);
CREATE INDEX idx_inserted_at ON conversation_events(inserted_at);
CREATE INDEX idx_event_type ON conversation_events(event_type);
CREATE INDEX idx_event_message ON conversation_events(event_message);
CREATE INDEX idx_event_git_branch ON conversation_events(event_git_branch);
CREATE INDEX idx_event_session_id ON conversation_events(event_session_id);
CREATE INDEX idx_event_uuid ON conversation_events(event_uuid);

COMMIT;

-- Verify migration
SELECT
    COUNT(*) as total_events,
    COUNT(event_message) as events_with_messages,
    COUNT(DISTINCT event_git_branch) as unique_branches,
    COUNT(DISTINCT event_session_id) as unique_sessions
FROM conversation_events;
