-- Reverse migration to restore original event_message generated column
-- MySQL version

USE wanderin_vibecheck;

-- Restore the original generated column formula
ALTER TABLE conversation_events
    MODIFY COLUMN event_message TEXT GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.message.content[0].text'))) STORED;

-- Verify the revert
SELECT
    COUNT(*) as total_messages,
    COUNT(event_message) as with_event_message,
    COUNT(*) - COUNT(event_message) as null_event_message
FROM conversation_events
WHERE JSON_EXTRACT(event_data, '$.message') IS NOT NULL;
