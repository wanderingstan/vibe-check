-- Database setup for Claude Code conversation monitoring
-- Run this in your wanderin_vibecheck database

USE wanderin_vibecheck;

CREATE TABLE IF NOT EXISTS conversation_events (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    file_name VARCHAR(255) NOT NULL,
    line_number INT NOT NULL,
    event_data JSON NOT NULL,
    inserted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY unique_event (file_name, line_number),
    INDEX idx_file_name (file_name),
    INDEX idx_inserted_at (inserted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
