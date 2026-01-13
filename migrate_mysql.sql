-- MySQL Migration Script
-- Migrates conversation_events table to new schema with updated generated columns
--
-- IMPORTANT: Backup your database first!
-- mysqldump -u username -p wanderin_vibecheck > backup_$(date +%Y%m%d_%H%M%S).sql
--
-- Run with:
-- mysql -u username -p wanderin_vibecheck < migrate_mysql.sql

USE wanderin_vibecheck;

-- Start transaction
START TRANSACTION;

-- Drop old indexes that we'll recreate
DROP INDEX idx_has_message ON conversation_events;
DROP INDEX idx_session_id ON conversation_events;

-- Drop old generated columns
ALTER TABLE conversation_events
    DROP COLUMN has_message,
    DROP COLUMN session_id;

-- Add new generated columns
ALTER TABLE conversation_events
    ADD COLUMN event_message TEXT GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.message.content[0].text'))) STORED,
    ADD COLUMN event_git_branch VARCHAR(255) GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.gitBranch'))) STORED,
    ADD COLUMN event_session_id VARCHAR(100) GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.sessionId'))) STORED,
    ADD COLUMN event_uuid VARCHAR(100) GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.uuid'))) STORED,
    ADD COLUMN event_timestamp VARCHAR(50) GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.timestamp'))) STORED;

-- Create indexes for new columns
CREATE INDEX idx_event_message ON conversation_events(event_message(255));
CREATE INDEX idx_event_git_branch ON conversation_events(event_git_branch);
CREATE INDEX idx_event_session_id ON conversation_events(event_session_id);
CREATE INDEX idx_event_uuid ON conversation_events(event_uuid);

COMMIT;

-- Verify migration
SELECT
    COUNT(*) as total_events,
    COUNT(event_message) as events_with_messages,
    COUNT(DISTINCT event_git_branch) as unique_branches,
    COUNT(DISTINCT event_session_id) as unique_sessions,
    COUNT(DISTINCT event_uuid) as unique_uuids
FROM conversation_events;
