-- Complete schema for Vibe Check server

USE wanderin_vibecheck;

-- Conversation events table
CREATE TABLE IF NOT EXISTS conversation_events (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    file_name VARCHAR(255) NOT NULL,
    line_number INT NOT NULL,
    event_data JSON NOT NULL,
    user_name VARCHAR(100) NOT NULL,
    inserted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- Generated columns for efficient querying
    event_type VARCHAR(50) GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.type'))) STORED,
    event_message TEXT GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.message.content[0].text'))) STORED,
    event_git_branch VARCHAR(255) GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.gitBranch'))) STORED,
    event_session_id VARCHAR(100) GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.sessionId'))) STORED,
    event_uuid VARCHAR(100) GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.uuid'))) STORED,
    event_timestamp VARCHAR(50) GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.timestamp'))) STORED,
    git_remote_url VARCHAR(500),
    git_commit_hash VARCHAR(40),
    UNIQUE KEY unique_event (file_name, line_number),
    INDEX idx_file_name (file_name),
    INDEX idx_user_name (user_name),
    INDEX idx_inserted_at (inserted_at),
    INDEX idx_event_type (event_type),
    INDEX idx_event_message (event_message(255)),
    INDEX idx_event_git_branch (event_git_branch),
    INDEX idx_event_session_id (event_session_id),
    INDEX idx_event_uuid (event_uuid),
    INDEX idx_git_remote_url (git_remote_url),
    INDEX idx_git_commit_hash (git_commit_hash)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- API Keys table for authentication
CREATE TABLE IF NOT EXISTS api_keys (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_name VARCHAR(100) NOT NULL UNIQUE,
    api_key VARCHAR(64) NOT NULL UNIQUE,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_used_at TIMESTAMP NULL,
    INDEX idx_api_key (api_key),
    INDEX idx_active (is_active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Example: Insert a test user (change the API key!)
-- First generate a key: python3 -c "import secrets; print(secrets.token_urlsafe(32))"
-- Then run: INSERT INTO api_keys (user_name, api_key) VALUES ('stan', 'your-generated-key-here');
