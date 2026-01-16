-- Migration to fix event_message generated column to handle both array and string formats
-- MySQL version

USE wanderin_vibecheck;

-- Drop the existing generated column and recreate it with the fixed formula
ALTER TABLE conversation_events
    MODIFY COLUMN event_message TEXT GENERATED ALWAYS AS
        (CASE
            WHEN LEFT(JSON_EXTRACT(event_data, '$.message.content'), 1) = '['
            THEN JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.message.content[0].text'))
            ELSE JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.message.content'))
        END) STORED;

-- Verify the fix
SELECT
    COUNT(*) as total_messages,
    COUNT(event_message) as with_event_message,
    COUNT(*) - COUNT(event_message) as null_event_message
FROM conversation_events
WHERE JSON_EXTRACT(event_data, '$.message') IS NOT NULL;
