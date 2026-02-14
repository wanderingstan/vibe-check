#!/usr/bin/env python3
"""
vibe-check: Claude Code Conversation Monitor

Monitors .jsonl files in the Claude Code conversations directory and
sends new events to the Vibe Check API server.
"""

import argparse
import copy
from datetime import datetime, timezone
import json
import logging
from logging.handlers import RotatingFileHandler
import os
import platform
import signal
import subprocess
import sys
import threading
import time
import webbrowser
from pathlib import Path
from typing import Optional, Tuple

import requests
import sqlite3
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler, FileModifiedEvent

from secret_detector import redact_if_secret

# Configure logging with timestamp format
LOG_FORMAT = "%(asctime)s %(levelname)s %(message)s"
LOG_DATE_FORMAT = "%Y-%m-%d %H:%M:%S"

# Log rotation settings
MAX_LOG_SIZE = 5 * 1024 * 1024  # 5 MB
LOG_BACKUP_COUNT = 3  # Keep 3 rotated files (.log.1, .log.2, .log.3)

# Create module-level logger
logger = logging.getLogger("vibe-check")

# Version
VERSION = "1.1.13"

# Default production API URL
DEFAULT_API_URL = "https://vibecheck.wanderingstan.com/api"


def setup_logging(log_file: Optional[Path] = None, verbose: bool = False):
    """Configure logging with optional file output."""
    level = logging.DEBUG if verbose else logging.INFO

    # Clear any existing handlers
    logger.handlers.clear()
    logger.setLevel(level)

    formatter = logging.Formatter(LOG_FORMAT, datefmt=LOG_DATE_FORMAT)

    if log_file:
        # Rotating file handler for daemon mode (auto-rotates at MAX_LOG_SIZE)
        log_file.parent.mkdir(parents=True, exist_ok=True)
        file_handler = RotatingFileHandler(
            log_file, maxBytes=MAX_LOG_SIZE, backupCount=LOG_BACKUP_COUNT
        )
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)
    else:
        # Console handler for interactive mode
        console_handler = logging.StreamHandler()
        console_handler.setFormatter(formatter)
        logger.addHandler(console_handler)


def get_git_info(directory: Path) -> Tuple[Optional[str], Optional[str]]:
    """
    Get git remote URL and commit hash from a directory.
    Returns (remote_url, commit_hash) or (None, None) if not a git repo.
    """
    if not directory or not directory.exists():
        return None, None

    try:
        # Get remote URL
        result = subprocess.run(
            ["git", "-C", str(directory), "remote", "get-url", "origin"],
            capture_output=True,
            text=True,
            timeout=1,
        )
        remote_url = result.stdout.strip() if result.returncode == 0 else None

        # Get commit hash
        result = subprocess.run(
            ["git", "-C", str(directory), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=1,
        )
        commit_hash = result.stdout.strip() if result.returncode == 0 else None

        return remote_url, commit_hash
    except (subprocess.TimeoutExpired, FileNotFoundError, Exception):
        return None, None


class StateManager:
    """Manages state tracking for file processing using SQLite.

    Thread-safe: All operations are protected by a reentrant lock.
    """

    def __init__(self, db_path: Path):
        self.db_path = db_path
        self.connection = None
        self.cursor = None
        self._lock = threading.RLock()
        self._connect()
        self._migrate_from_json()

    def _connect(self):
        """Establish SQLite connection with thread-safety settings."""
        self.connection = sqlite3.connect(
            str(self.db_path),
            timeout=30.0,  # Wait up to 30 seconds for locks
            check_same_thread=False,
        )
        self.cursor = self.connection.cursor()

        # Enable WAL mode for better concurrent access
        self.cursor.execute("PRAGMA journal_mode=WAL")
        self.cursor.execute("PRAGMA synchronous=NORMAL")
        self.cursor.execute("PRAGMA busy_timeout=30000")  # 30 second busy timeout

        # Ensure table exists (in case StateManager is created before SQLiteManager)
        self.cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS conversation_file_state (
                file_name TEXT PRIMARY KEY,
                last_line INTEGER NOT NULL DEFAULT 0,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """
        )
        self.connection.commit()
        # Log count of tracked files
        self.cursor.execute("SELECT COUNT(*) FROM conversation_file_state")
        count = self.cursor.fetchone()[0]
        logger.info(f"StateManager connected: {count} files tracked (WAL mode enabled)")

    def _migrate_from_json(self):
        """Migrate data from legacy state.json if it exists."""
        legacy_state_file = self.db_path.parent / "state.json"
        if not legacy_state_file.exists():
            return

        try:
            with open(legacy_state_file, "r") as f:
                legacy_state = json.load(f)

            if not legacy_state:
                return

            with self._lock:
                # Check if we've already migrated (table has data)
                self.cursor.execute("SELECT COUNT(*) FROM conversation_file_state")
                if self.cursor.fetchone()[0] > 0:
                    logger.debug("State already migrated, skipping JSON import")
                    return

                logger.info(f"Migrating {len(legacy_state)} entries from state.json...")
                for filename, last_line in legacy_state.items():
                    self.cursor.execute(
                        """
                        INSERT OR REPLACE INTO conversation_file_state (file_name, last_line)
                        VALUES (?, ?)
                    """,
                        (filename, last_line),
                    )
                self.connection.commit()
            logger.info("Migration complete")

            # Rename old file as backup
            backup_path = legacy_state_file.with_suffix(".json.bak")
            legacy_state_file.rename(backup_path)
            logger.info(f"Legacy state.json backed up to {backup_path}")

        except (json.JSONDecodeError, IOError) as e:
            logger.warning(f"Could not migrate from state.json: {e}")

    def get_last_line(self, filename: str) -> int:
        """Get the last processed line number for a file."""
        with self._lock:
            self.cursor.execute(
                "SELECT last_line FROM conversation_file_state WHERE file_name = ?",
                (filename,),
            )
            row = self.cursor.fetchone()
            return row[0] if row else 0

    def set_last_line(self, filename: str, line_number: int):
        """Set the last processed line number for a file."""
        with self._lock:
            self.cursor.execute(
                """
                INSERT INTO conversation_file_state (file_name, last_line, updated_at)
                VALUES (?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(file_name) DO UPDATE SET
                    last_line = excluded.last_line,
                    updated_at = CURRENT_TIMESTAMP
            """,
                (filename, line_number),
            )
            self.connection.commit()

    def skip_to_end(self, directory: Path, debug_filter_project: Optional[str] = None):
        """Fast-forward state to the end of all existing files without processing."""
        logger.info("Skipping backlog - fast-forwarding to current position...")
        count = 0
        updates = []

        for file_path in directory.glob("**/*.jsonl"):
            if not file_path.exists():
                continue

            try:
                # Get relative path for consistent naming
                relative_path = file_path.relative_to(directory)
                filename = str(relative_path)
            except ValueError:
                filename = file_path.name

            # Apply debug filter if configured
            if debug_filter_project and not filename.startswith(debug_filter_project):
                continue

            # Count lines in file
            try:
                with open(file_path, "r", encoding="utf-8") as f:
                    line_count = sum(1 for _ in f)

                if line_count > 0:
                    updates.append((filename, line_count))
                    logger.debug(f"Skipped {line_count} lines in {filename}")
                    count += 1
            except Exception as e:
                logger.error(f"Error reading {filename}: {e}")

        # Batch insert/update all at once for efficiency
        if updates:
            with self._lock:
                self.cursor.executemany(
                    """
                    INSERT INTO conversation_file_state (file_name, last_line, updated_at)
                    VALUES (?, ?, CURRENT_TIMESTAMP)
                    ON CONFLICT(file_name) DO UPDATE SET
                        last_line = excluded.last_line,
                        updated_at = CURRENT_TIMESTAMP
                """,
                    updates,
                )
                self.connection.commit()

        logger.info(
            f"Fast-forwarded {count} file(s). Monitoring will start from current position."
        )

    def get_file_count(self) -> int:
        """Get the number of tracked conversation files."""
        with self._lock:
            self.cursor.execute("SELECT COUNT(*) FROM conversation_file_state")
            return self.cursor.fetchone()[0]

    def close(self):
        """Close the database connection."""
        with self._lock:
            if self.connection:
                self.connection.close()


class SQLiteManager:
    """Manages SQLite database connections and operations.

    Thread-safe: All operations are protected by a reentrant lock.
    """

    def __init__(self, config: dict):
        """Initialize SQLite manager with configuration."""
        self.config = config
        self.enabled = config.get("enabled", True)
        self.user_name = config.get("user_name", "unknown")
        self.connection = None
        self.cursor = None
        self.db_path = None
        self._lock = threading.RLock()

        if not self.enabled:
            logger.info("SQLite recording is disabled")
            return

        try:
            # Expand path and create database
            self.db_path = Path(config["database_path"]).expanduser()
            self.db_path.parent.mkdir(parents=True, exist_ok=True)

            self.connect()
            self.create_schema()
            self._migrate_schema()
            self.export_schema_docs()
            logger.info(f"Connected to SQLite database: {self.db_path}")
        except Exception as e:
            logger.error(f"Error initializing SQLite: {e}")
            logger.warning(
                "SQLite recording will be disabled. Events will still be sent to API."
            )
            self.enabled = False

    def connect(self):
        """Establish SQLite connection with thread-safety settings."""
        self.connection = sqlite3.connect(
            str(self.db_path),
            timeout=30.0,  # Wait up to 30 seconds for locks
            check_same_thread=False,
        )
        self.cursor = self.connection.cursor()

        # Enable WAL mode for better concurrent access
        self.cursor.execute("PRAGMA journal_mode=WAL")
        self.cursor.execute("PRAGMA synchronous=NORMAL")
        self.cursor.execute("PRAGMA busy_timeout=30000")  # 30 second busy timeout

    def create_schema(self):
        """Create database schema if it doesn't exist."""
        with self._lock:
            self.cursor.execute(
                """
                CREATE TABLE IF NOT EXISTS conversation_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_name TEXT NOT NULL,
                line_number INTEGER NOT NULL,
                event_data TEXT NOT NULL,
                user_name TEXT NOT NULL,
                inserted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                event_type TEXT GENERATED ALWAYS AS
                    (json_extract(event_data, '$.type')) STORED,
                event_message TEXT GENERATED ALWAYS AS (
                    COALESCE(
                        -- Array of content blocks: {"message": {"content": [{"text": "..."}, ...]}}
                        json_extract(event_data, '$.message.content[0].text') ||
                        IIF(json_extract(event_data, '$.message.content[1].text') IS NOT NULL,
                            char(10) || char(10) || json_extract(event_data, '$.message.content[1].text'), '') ||
                        IIF(json_extract(event_data, '$.message.content[2].text') IS NOT NULL,
                            char(10) || char(10) || json_extract(event_data, '$.message.content[2].text'), '') ||
                        IIF(json_extract(event_data, '$.message.content[3].text') IS NOT NULL,
                            char(10) || char(10) || json_extract(event_data, '$.message.content[3].text'), '') ||
                        IIF(json_extract(event_data, '$.message.content[4].text') IS NOT NULL,
                            char(10) || char(10) || json_extract(event_data, '$.message.content[4].text'), ''),
                        -- Plain string content: {"message": {"content": "some text"}}
                        IIF(json_type(event_data, '$.message.content') = 'text',
                            json_extract(event_data, '$.message.content'), NULL),
                        -- Fallback to top-level content field
                        json_extract(event_data, '$.content')
                    )
                ) STORED,
                event_git_branch TEXT GENERATED ALWAYS AS
                    (json_extract(event_data, '$.gitBranch')) STORED,
                event_session_id TEXT GENERATED ALWAYS AS
                    (json_extract(event_data, '$.sessionId')) STORED,
                event_uuid TEXT GENERATED ALWAYS AS
                    (json_extract(event_data, '$.uuid')) STORED,
                event_timestamp TEXT GENERATED ALWAYS AS
                    (json_extract(event_data, '$.timestamp')) STORED,
                event_model TEXT GENERATED ALWAYS AS
                    (json_extract(event_data, '$.message.model')) STORED,
                event_input_tokens INTEGER GENERATED ALWAYS AS
                    (json_extract(event_data, '$.message.usage.input_tokens')) STORED,
                event_cache_creation_input_tokens INTEGER GENERATED ALWAYS AS
                    (json_extract(event_data, '$.message.usage.cache_creation_input_tokens')) STORED,
                event_cache_read_input_tokens INTEGER GENERATED ALWAYS AS
                    (json_extract(event_data, '$.message.usage.cache_read_input_tokens')) STORED,
                event_output_tokens INTEGER GENERATED ALWAYS AS
                    (json_extract(event_data, '$.message.usage.output_tokens')) STORED,
                git_remote_url TEXT,
                git_commit_hash TEXT,
                synced_at DATETIME DEFAULT NULL,
                    UNIQUE(file_name, line_number)
            )
            """
            )

            # Create indexes
            self.cursor.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_file_name ON conversation_events(file_name)
            """
            )
            self.cursor.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_user_name ON conversation_events(user_name)
            """
            )
            self.cursor.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_inserted_at ON conversation_events(inserted_at)
            """
            )
            self.cursor.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_event_type ON conversation_events(event_type)
            """
            )
            self.cursor.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_event_message ON conversation_events(event_message)
            """
            )
            self.cursor.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_event_git_branch ON conversation_events(event_git_branch)
            """
            )
            self.cursor.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_event_session_id ON conversation_events(event_session_id)
            """
            )
            self.cursor.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_event_uuid ON conversation_events(event_uuid)
            """
            )
            self.cursor.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_git_remote_url ON conversation_events(git_remote_url)
            """
            )
            self.cursor.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_git_commit_hash ON conversation_events(git_commit_hash)
            """
            )
            self.cursor.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_synced_at ON conversation_events(synced_at)
            """
            )

            # Create FTS5 virtual table for full-text search
            self.cursor.execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                    event_message,
                    event_type,
                    event_session_id,
                    content=conversation_events,
                    content_rowid=id
                )
            """
            )

            # Create triggers to keep FTS5 in sync with conversation_events
            self.cursor.execute(
                """
                CREATE TRIGGER IF NOT EXISTS messages_fts_insert
                AFTER INSERT ON conversation_events
                WHEN new.event_message IS NOT NULL
                BEGIN
                    INSERT INTO messages_fts(rowid, event_message, event_type, event_session_id)
                    VALUES (new.id, new.event_message, new.event_type, new.event_session_id);
                END
            """
            )

            self.cursor.execute(
                """
                CREATE TRIGGER IF NOT EXISTS messages_fts_delete
                AFTER DELETE ON conversation_events
                BEGIN
                    DELETE FROM messages_fts WHERE rowid = old.id;
                END
            """
            )

            self.cursor.execute(
                """
                CREATE TRIGGER IF NOT EXISTS messages_fts_update
                AFTER UPDATE ON conversation_events
                WHEN new.event_message IS NOT NULL
                BEGIN
                    UPDATE messages_fts
                    SET event_message = new.event_message,
                        event_type = new.event_type,
                        event_session_id = new.event_session_id
                    WHERE rowid = new.id;
                END
            """
            )

            # Create conversation_file_state table for tracking processed lines
            self.cursor.execute(
                """
                CREATE TABLE IF NOT EXISTS conversation_file_state (
                    file_name TEXT PRIMARY KEY,
                    last_line INTEGER NOT NULL DEFAULT 0,
                    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
            """
            )

            self.connection.commit()

    def export_schema_docs(self):
        """Export schema documentation to ~/.vibe-check/SCHEMA.md for reference by tools."""
        if not self.enabled or not self.cursor:
            return

        try:
            with self._lock:
                schema_file = Path.home() / ".vibe-check" / "SCHEMA.md"

                output = "# Vibe-Check Database Schema\n\n"
                output += "_Auto-generated from database. Do not edit manually._\n\n"

                # Get all tables
                tables = self.cursor.execute(
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            ).fetchall()

            for (table_name,) in tables:
                output += f"## Table: {table_name}\n\n"

                # Get column info
                columns = self.cursor.execute(f"PRAGMA table_info({table_name})").fetchall()

                output += "| Column | Type | Nullable | Default | Key |\n"
                output += "|--------|------|----------|---------|-----|\n"

                for col in columns:
                    _, name, type_, notnull, dflt_value, pk = col
                    nullable = "No" if notnull else "Yes"
                    default = dflt_value if dflt_value else "-"
                    key = "PK" if pk else ""
                    output += f"| {name} | {type_} | {nullable} | {default} | {key} |\n"

                output += "\n"

                # Get indexes for this table
                indexes = self.cursor.execute(f"PRAGMA index_list({table_name})").fetchall()
                if indexes:
                    output += "**Indexes:**\n"
                    for idx in indexes:
                        idx_name = idx[1]
                        idx_cols = self.cursor.execute(f"PRAGMA index_info({idx_name})").fetchall()
                        cols = [col[2] for col in idx_cols]  # col[2] is the column name
                        output += f"- `{idx_name}` on ({', '.join(cols)})\n"
                    output += "\n"

                output += "---\n\n"

            # Add notes about generated columns
            output += "## Important Notes\n\n"
            output += "### Generated Columns in conversation_events\n\n"
            output += "The following columns are GENERATED ALWAYS (automatically computed from `event_data` JSON):\n\n"
            output += "- `event_type` - Event type (user, assistant, etc.)\n"
            output += "- `event_message` - Extracted message text\n"
            output += "- `event_session_id` - Session identifier\n"
            output += "- `event_git_branch` - Git branch name\n"
            output += "- `event_uuid` - Unique event identifier\n"
            output += "- `event_timestamp` - Event timestamp\n"
            output += "- `event_model` - Claude model used\n"
            output += "- `event_input_tokens` - Token usage (input)\n"
            output += "- `event_cache_creation_input_tokens` - Cache creation tokens\n"
            output += "- `event_cache_read_input_tokens` - Cache read tokens\n"
            output += "- `event_output_tokens` - Token usage (output)\n\n"
            output += "**Best Practice:** Query generated columns directly rather than extracting from JSON.\n\n"
            output += "### FTS5 Full-Text Search (messages_fts)\n\n"
            output += "The `messages_fts` virtual table provides fast full-text search with relevance ranking:\n\n"
            output += "**Features:**\n"
            output += "- 10-100x faster than LIKE '%text%' queries\n"
            output += "- BM25 relevance ranking (lower rank = more relevant)\n"
            output += "- Automatically synced with conversation_events via triggers\n\n"
            output += "**Query Syntax:**\n"
            output += "- Simple: `authentication`\n"
            output += "- Phrase: `\"user login\"`\n"
            output += "- Boolean: `auth AND oauth`, `login NOT password`\n"
            output += "- Prefix: `auth*` (matches authentication, authorize, etc.)\n\n"
            output += "**Example:**\n"
            output += "```sql\n"
            output += "SELECT ce.event_type, ce.event_message, fts.rank\n"
            output += "FROM messages_fts fts\n"
            output += "JOIN conversation_events ce ON ce.id = fts.rowid\n"
            output += "WHERE messages_fts MATCH 'authentication AND oauth'\n"
            output += "ORDER BY fts.rank\n"
            output += "LIMIT 10;\n"
            output += "```\n\n"
            output += "### Database Configuration\n\n"
            output += "- Uses WAL mode for concurrent access\n"
            output += "- event_message extracts text from various JSON structures automatically\n"
            output += "- All date/time columns use DATETIME type with CURRENT_TIMESTAMP default\n"

            # Write to file
            schema_file.write_text(output)
            logger.info(f"Schema documentation exported to {schema_file}")

        except Exception as e:
            logger.warning(f"Failed to export schema docs: {e}")
            # Non-fatal - don't stop startup if this fails

    def _migrate_schema(self):
        """Run schema migrations for existing databases."""
        with self._lock:
            # Check if synced_at column exists
            # Use table_xinfo to include generated columns (table_info excludes them)
            self.cursor.execute("PRAGMA table_xinfo(conversation_events)")
            columns = [row[1] for row in self.cursor.fetchall()]

            if "synced_at" not in columns:
                logger.info("Migrating schema: adding synced_at column...")
                self.cursor.execute(
                    """
                    ALTER TABLE conversation_events
                    ADD COLUMN synced_at DATETIME DEFAULT NULL
                """
                )
                # Add index for efficient queries on unsynced events
                self.cursor.execute(
                    """
                    CREATE INDEX IF NOT EXISTS idx_synced_at
                    ON conversation_events(synced_at)
                """
                )
                self.connection.commit()
                logger.info("Schema migration complete: synced_at column added")

            # Check if token columns exist (added for usage tracking)
            # SQLite doesn't allow adding STORED generated columns via ALTER TABLE,
            # so we need to recreate the table if these columns are missing
            if "event_model" not in columns:
                logger.info("Migrating schema: adding token tracking columns...")
                self._recreate_table_with_new_schema()
                logger.info("Schema migration complete: token columns added")

            # Check if FTS5 table exists and needs population
            self.cursor.execute(
                """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name='messages_fts'
            """
            )
            fts_exists = self.cursor.fetchone() is not None

            if not fts_exists:
                logger.info("Migrating schema: creating FTS5 full-text search index...")
                # FTS5 table and triggers will be created by create_schema()
                # Just need to populate it with existing data
                self._populate_fts_table()
                logger.info("Schema migration complete: FTS5 index created and populated")
            else:
                # Check if FTS5 table needs population (empty but main table has data)
                self.cursor.execute("SELECT COUNT(*) FROM messages_fts")
                fts_count = self.cursor.fetchone()[0]
                self.cursor.execute(
                    "SELECT COUNT(*) FROM conversation_events WHERE event_message IS NOT NULL"
                )
                main_count = self.cursor.fetchone()[0]

                if fts_count == 0 and main_count > 0:
                    logger.info(
                        f"FTS5 table is empty but main table has {main_count:,} messages. Populating..."
                    )
                    self._populate_fts_table()
                    logger.info("FTS5 table populated successfully")

    def _recreate_table_with_new_schema(self):
        """Recreate conversation_events table to add new generated columns.

        SQLite doesn't support ALTER TABLE ADD COLUMN for STORED generated columns,
        so we must recreate the table with the new schema.
        """
        # Get row count for progress logging
        self.cursor.execute("SELECT COUNT(*) FROM conversation_events")
        row_count = self.cursor.fetchone()[0]
        logger.info(f"Migration: processing {row_count:,} rows...")

        # Save dependent view definitions before dropping the table
        self.cursor.execute(
            """
            SELECT name, sql FROM sqlite_master
            WHERE type='view' AND sql LIKE '%conversation_events%'
        """
        )
        views = self.cursor.fetchall()
        if views:
            logger.info(f"Migration: preserving {len(views)} dependent view(s)")

        # Drop dependent views first
        for view_name, _ in views:
            self.cursor.execute(f"DROP VIEW IF EXISTS {view_name}")

        # Create new table with updated schema
        self.cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS conversation_events_new (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_name TEXT NOT NULL,
                line_number INTEGER NOT NULL,
                event_data TEXT NOT NULL,
                user_name TEXT NOT NULL,
                inserted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                event_type TEXT GENERATED ALWAYS AS
                    (json_extract(event_data, '$.type')) STORED,
                event_message TEXT GENERATED ALWAYS AS (
                    COALESCE(
                        json_extract(event_data, '$.message.content[0].text') ||
                        IIF(json_extract(event_data, '$.message.content[1].text') IS NOT NULL,
                            char(10) || char(10) || json_extract(event_data, '$.message.content[1].text'), '') ||
                        IIF(json_extract(event_data, '$.message.content[2].text') IS NOT NULL,
                            char(10) || char(10) || json_extract(event_data, '$.message.content[2].text'), '') ||
                        IIF(json_extract(event_data, '$.message.content[3].text') IS NOT NULL,
                            char(10) || char(10) || json_extract(event_data, '$.message.content[3].text'), '') ||
                        IIF(json_extract(event_data, '$.message.content[4].text') IS NOT NULL,
                            char(10) || char(10) || json_extract(event_data, '$.message.content[4].text'), ''),
                        IIF(json_type(event_data, '$.message.content') = 'text',
                            json_extract(event_data, '$.message.content'), NULL),
                        json_extract(event_data, '$.content')
                    )
                ) STORED,
                event_git_branch TEXT GENERATED ALWAYS AS
                    (json_extract(event_data, '$.gitBranch')) STORED,
                event_session_id TEXT GENERATED ALWAYS AS
                    (json_extract(event_data, '$.sessionId')) STORED,
                event_uuid TEXT GENERATED ALWAYS AS
                    (json_extract(event_data, '$.uuid')) STORED,
                event_timestamp TEXT GENERATED ALWAYS AS
                    (json_extract(event_data, '$.timestamp')) STORED,
                event_model TEXT GENERATED ALWAYS AS
                    (json_extract(event_data, '$.message.model')) STORED,
                event_input_tokens INTEGER GENERATED ALWAYS AS
                    (json_extract(event_data, '$.message.usage.input_tokens')) STORED,
                event_cache_creation_input_tokens INTEGER GENERATED ALWAYS AS
                    (json_extract(event_data, '$.message.usage.cache_creation_input_tokens')) STORED,
                event_cache_read_input_tokens INTEGER GENERATED ALWAYS AS
                    (json_extract(event_data, '$.message.usage.cache_read_input_tokens')) STORED,
                event_output_tokens INTEGER GENERATED ALWAYS AS
                    (json_extract(event_data, '$.message.usage.output_tokens')) STORED,
                git_remote_url TEXT,
                git_commit_hash TEXT,
                synced_at DATETIME DEFAULT NULL,
                UNIQUE(file_name, line_number)
            )
        """
        )

        # Copy data from old table (only non-generated columns)
        self.cursor.execute(
            """
            INSERT INTO conversation_events_new
                (id, file_name, line_number, event_data, user_name, inserted_at,
                 git_remote_url, git_commit_hash, synced_at)
            SELECT id, file_name, line_number, event_data, user_name, inserted_at,
                   git_remote_url, git_commit_hash, synced_at
            FROM conversation_events
        """
        )

        # Drop old table and rename new one
        self.cursor.execute("DROP TABLE conversation_events")
        self.cursor.execute(
            "ALTER TABLE conversation_events_new RENAME TO conversation_events"
        )

        # Recreate indexes
        self.cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_file_name ON conversation_events(file_name)"
        )
        self.cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_user_name ON conversation_events(user_name)"
        )
        self.cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_inserted_at ON conversation_events(inserted_at)"
        )
        self.cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_event_type ON conversation_events(event_type)"
        )
        self.cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_event_message ON conversation_events(event_message)"
        )
        self.cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_event_git_branch ON conversation_events(event_git_branch)"
        )
        self.cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_event_session_id ON conversation_events(event_session_id)"
        )
        self.cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_event_uuid ON conversation_events(event_uuid)"
        )
        self.cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_event_timestamp ON conversation_events(event_timestamp)"
        )
        self.cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_synced_at ON conversation_events(synced_at)"
        )
        self.cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_event_model ON conversation_events(event_model)"
        )

        # Recreate dependent views
        for view_name, view_sql in views:
            if view_sql:
                logger.info(f"Migration: recreating view '{view_name}'")
                self.cursor.execute(view_sql)

        self.connection.commit()
        logger.info(f"Migration: complete ({row_count:,} rows migrated)")

    def insert_event(
        self,
        filename: str,
        line_number: int,
        event_data: dict,
        git_remote_url: Optional[str] = None,
        git_commit_hash: Optional[str] = None,
    ) -> Optional[int]:
        """Insert an event into the SQLite database.

        Returns:
            The row ID of the inserted event, or None on failure.
        """
        if not self.enabled:
            return None

        try:
            # Convert event_data to JSON string
            event_json = json.dumps(event_data)

            with self._lock:
                # Insert or ignore duplicates
                query = """
                    INSERT OR IGNORE INTO conversation_events
                    (file_name, line_number, event_data, user_name, git_remote_url, git_commit_hash)
                    VALUES (?, ?, ?, ?, ?, ?)
                """
                self.cursor.execute(
                    query,
                    (
                        filename,
                        line_number,
                        event_json,
                        self.user_name,
                        git_remote_url,
                        git_commit_hash,
                    ),
                )
                self.connection.commit()

                # Return the row ID (lastrowid is 0 if INSERT OR IGNORE skipped)
                if self.cursor.lastrowid:
                    return self.cursor.lastrowid

                # If ignored (duplicate), find the existing row ID
                self.cursor.execute(
                    "SELECT id FROM conversation_events WHERE file_name = ? AND line_number = ?",
                    (filename, line_number),
                )
                row = self.cursor.fetchone()
                return row[0] if row else None

        except sqlite3.Error as e:
            logger.error(f"SQLite error: {e}")
            return None

    def insert_events_batch(
        self,
        events: list,
    ) -> int:
        """Insert multiple events into the SQLite database in a single transaction.

        Args:
            events: List of tuples (filename, line_number, event_json, git_remote_url, git_commit_hash)

        Returns:
            Number of events successfully inserted (excludes duplicates).
        """
        if not self.enabled or not events:
            return 0

        try:
            with self._lock:
                query = """
                    INSERT OR IGNORE INTO conversation_events
                    (file_name, line_number, event_data, user_name, git_remote_url, git_commit_hash)
                    VALUES (?, ?, ?, ?, ?, ?)
                """
                # Add user_name to each event tuple
                events_with_user = [
                    (e[0], e[1], e[2], self.user_name, e[3], e[4]) for e in events
                ]
                self.cursor.executemany(query, events_with_user)
                inserted_count = self.cursor.rowcount
                self.connection.commit()
                return inserted_count if inserted_count > 0 else len(events)

        except sqlite3.Error as e:
            logger.error(f"SQLite batch insert error: {e}")
            return 0

    def _populate_fts_table(self):
        """Populate FTS5 table with existing data from conversation_events.

        This is called during migration when the FTS5 table is first created
        or when it's empty but the main table has data.
        """
        try:
            # Get count of messages to populate
            self.cursor.execute(
                "SELECT COUNT(*) FROM conversation_events WHERE event_message IS NOT NULL"
            )
            message_count = self.cursor.fetchone()[0]

            if message_count == 0:
                logger.info("No messages to populate in FTS5 table")
                return

            logger.info(f"Populating FTS5 index with {message_count:,} messages...")

            # Insert in batches for progress tracking and memory efficiency
            batch_size = 1000
            offset = 0

            while offset < message_count:
                self.cursor.execute(
                    """
                    INSERT INTO messages_fts(rowid, event_message, event_type, event_session_id)
                    SELECT id, event_message, event_type, event_session_id
                    FROM conversation_events
                    WHERE event_message IS NOT NULL
                    ORDER BY id
                    LIMIT ? OFFSET ?
                """,
                    (batch_size, offset),
                )
                self.connection.commit()
                offset += batch_size

                # Log progress every 10k messages
                if offset % 10000 == 0:
                    logger.info(f"FTS5 population progress: {offset:,}/{message_count:,} messages")

            logger.info(f"FTS5 index populated with {message_count:,} messages")

        except sqlite3.Error as e:
            logger.error(f"Error populating FTS5 table: {e}")
            # Don't raise - this is non-fatal, search will just fall back to LIKE queries

    def mark_event_synced(self, event_id: int) -> bool:
        """Mark an event as synced to the remote API.

        Args:
            event_id: The row ID of the event to mark as synced.

        Returns:
            True if successful, False otherwise.
        """
        if not self.enabled:
            return False

        try:
            with self._lock:
                self.cursor.execute(
                    "UPDATE conversation_events SET synced_at = CURRENT_TIMESTAMP WHERE id = ?",
                    (event_id,),
                )
                self.connection.commit()
                return self.cursor.rowcount > 0
        except sqlite3.Error as e:
            logger.error(f"SQLite error marking event synced: {e}")
            return False

    def get_unsynced_events(self, limit: int = 50) -> list:
        """Get events that haven't been synced to the remote API.

        Args:
            limit: Maximum number of events to return.

        Returns:
            List of event dictionaries with id, file_name, line_number, event_data,
            git_remote_url, git_commit_hash.
        """
        if not self.enabled:
            return []

        try:
            with self._lock:
                self.cursor.execute(
                    """
                    SELECT id, file_name, line_number, event_data, git_remote_url, git_commit_hash
                    FROM conversation_events
                    WHERE synced_at IS NULL
                    ORDER BY id DESC
                    LIMIT ?
                """,
                    (limit,),
                )
                rows = self.cursor.fetchall()
            return [
                {
                    "id": row[0],
                    "file_name": row[1],
                    "line_number": row[2],
                    "event_data": json.loads(row[3]),
                    "git_remote_url": row[4],
                    "git_commit_hash": row[5],
                }
                for row in rows
            ]
        except sqlite3.Error as e:
            logger.error(f"SQLite error getting unsynced events: {e}")
            return []

    def get_sync_stats(self) -> dict:
        """Get sync statistics.

        Returns:
            Dictionary with total_events, synced_events, pending_events.
        """
        if not self.enabled:
            return {"total_events": 0, "synced_events": 0, "pending_events": 0}

        try:
            with self._lock:
                self.cursor.execute("SELECT COUNT(*) FROM conversation_events")
                total = self.cursor.fetchone()[0]

                self.cursor.execute(
                    "SELECT COUNT(*) FROM conversation_events WHERE synced_at IS NOT NULL"
                )
                synced = self.cursor.fetchone()[0]

            return {
                "total_events": total,
                "synced_events": synced,
                "pending_events": total - synced,
            }
        except sqlite3.Error as e:
            logger.error(f"SQLite error getting sync stats: {e}")
            return {"total_events": 0, "synced_events": 0, "pending_events": 0}

    def close(self):
        """Close SQLite connection."""
        with self._lock:
            if self.cursor:
                self.cursor.close()
            if self.connection:
                self.connection.close()

    def __del__(self):
        """Cleanup on deletion."""
        try:
            self.close()
        except:
            pass


class ConversationMonitor(FileSystemEventHandler):
    """Handles file system events for conversation files."""

    def __init__(
        self,
        api_config: dict,
        state_manager: StateManager,
        base_dir: Path,
        sqlite_manager: Optional[SQLiteManager] = None,
        debug_filter_project: Optional[str] = None,
    ):
        self.api_enabled = api_config.get("enabled", False)
        self.api_url = api_config.get("url", "")
        self.api_key = api_config.get("api_key", "")
        self.state_manager = state_manager
        self.base_dir = base_dir
        self.sqlite_manager = sqlite_manager
        self.debug_filter_project = debug_filter_project
        self.session = requests.Session()
        self.session.headers.update(
            {
                "X-API-Key": self.api_key,
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "VibeCheck-Monitor/1.0",
            }
        )

        self.api_endpoint = self.api_url
        if self.api_enabled:
            self.test_connection()
        else:
            logger.info("Remote API recording is disabled")

        # Background sync worker state
        self.sync_thread: Optional[threading.Thread] = None
        self.sync_running = False
        self.sync_backoff_delay = 0.1  # Start at 100ms between requests

        # Log configuration summary
        destinations = []
        if self.api_enabled:
            destinations.append(f"remote ({self.api_endpoint})")
        if sqlite_manager and sqlite_manager.enabled:
            destinations.append(f"local ({sqlite_manager.db_path})")
        if destinations:
            logger.info(f"Recording destinations: {', '.join(destinations)}")
        else:
            logger.warning("No recording destinations enabled!")

    def test_connection(self):
        """Test API connection. Non-fatal if connection fails."""
        try:
            # Try the configured URL first
            response = self.session.get(f"{self.api_endpoint}/health")
            response.raise_for_status()
            logger.info(f"Connected to API server: {self.api_endpoint}")
            return True
        except requests.RequestException as e:
            # If that fails and URL doesn't already have api.php, try adding it
            if "/api.php" not in self.api_endpoint:
                try:
                    self.api_endpoint = f"{self.api_url}/api.php"
                    response = self.session.get(f"{self.api_endpoint}/health")
                    response.raise_for_status()
                    logger.info(f"Connected to API server: {self.api_endpoint}")
                    return True
                except requests.RequestException:
                    pass

            logger.warning(f"Could not connect to remote API: {e}")
            logger.warning("Remote sync disabled. Local recording will continue.")
            self.api_enabled = False
            return False

    def process_file(self, file_path: Path):
        """Process new lines in a JSONL file.

        Uses batch inserts and single state update for efficiency.
        """
        if not file_path.suffix == ".jsonl":
            return

        if not file_path.exists():
            return

        # Get relative path from base directory for better identification
        try:
            relative_path = file_path.relative_to(self.base_dir)
            filename = str(relative_path)
        except ValueError:
            # Fallback to just filename if path is not relative to base_dir
            filename = file_path.name

        # DEBUG: Filter to only process specific project if configured
        if self.debug_filter_project:
            if not filename.startswith(self.debug_filter_project):
                return

        last_line = self.state_manager.get_last_line(filename)

        try:
            with open(file_path, "r", encoding="utf-8") as f:
                lines = f.readlines()

            # Process only new lines
            new_lines = lines[last_line:]
            if not new_lines:
                # Still track empty/fully-processed files so they count as "complete"
                if last_line == 0 and len(lines) == 0:
                    self.state_manager.set_last_line(filename, 0)
                return

            logger.info(f"Processing {len(new_lines)} new line(s) from {filename}")

            # Track counts and collect events for batch insert
            skipped_count = 0
            events_batch = []
            final_line_number = last_line

            # Get git info once for all events in this file
            git_remote_url, git_commit_hash = get_git_info(file_path.parent)

            for idx, line in enumerate(new_lines):
                line_number = last_line + idx + 1
                final_line_number = line_number
                line = line.strip()

                if not line:
                    skipped_count += 1
                    continue

                try:
                    # Parse JSON
                    event_data = json.loads(line)

                    # Redact secrets before storage
                    event_data = self.redact_secrets_from_event(event_data)
                    event_json = json.dumps(event_data)

                    # Collect for batch insert
                    events_batch.append(
                        (
                            filename,
                            line_number,
                            event_json,
                            git_remote_url,
                            git_commit_hash,
                        )
                    )

                except json.JSONDecodeError as e:
                    logger.warning(f"Invalid JSON at {filename}:{line_number}: {e}")
                    skipped_count += 1

            # Batch insert all events (single commit)
            stored_count = 0
            if events_batch and self.sqlite_manager and self.sqlite_manager.enabled:
                stored_count = self.sqlite_manager.insert_events_batch(events_batch)

            # Update state once at the end (single commit)
            self.state_manager.set_last_line(filename, final_line_number)

            # Log summary
            if stored_count > 0:
                sync_note = " (API sync pending)" if self.api_enabled else ""
                logger.info(
                    f"Stored {stored_count} event(s) from {filename}{sync_note}"
                )

        except Exception as e:
            logger.error(f"Error processing {file_path}: {e}")

    def redact_secrets_from_event(self, event_data: dict) -> dict:
        """
        Scan event data for secrets and redact them.

        Args:
            event_data: The event data dictionary

        Returns:
            Modified event data with secrets redacted
        """
        # Make a deep copy to avoid modifying the original
        event_data = copy.deepcopy(event_data)

        # Debug logging
        event_type = event_data.get("type")
        logger.debug(f"Event type: {event_type}")

        # Check if this is a user or assistant message with text content
        if event_type in ("user", "assistant", "message"):
            message = event_data.get("message", {})
            logger.debug(f"Message found: {bool(message)}")
            if message and "content" in message:
                content = message.get("content", [])
                logger.debug(
                    f"Content blocks: {len(content) if isinstance(content, list) else 0}"
                )
                if isinstance(content, list):
                    # Check each content block
                    for i, block in enumerate(content):
                        if isinstance(block, dict) and block.get("type") == "text":
                            text = block.get("text", "")
                            logger.debug(
                                f"Block {i} text length: {len(text)}, preview: {text[:100]}"
                            )
                            if text:
                                # Redact if secrets found
                                redacted_text = redact_if_secret(text)
                                if redacted_text != text:
                                    # Create a new content block with redacted text
                                    event_data["message"]["content"][i] = {
                                        **block,
                                        "text": redacted_text,
                                    }
                                    logger.warning(
                                        "Secret detected and redacted in message"
                                    )
                                else:
                                    logger.debug(f"No secrets found in block {i}")

        return event_data

    def insert_event(self, filename: str, line_number: int, event_data: dict) -> bool:
        """Insert an event to local SQLite database.

        API sync is handled separately by the background sync worker.
        This keeps file monitoring fast and decoupled from network latency.

        Returns:
            True if SQLite insert succeeded, False otherwise.
        """
        if not self.sqlite_manager or not self.sqlite_manager.enabled:
            logger.warning("SQLite not enabled - event not stored")
            return False

        # Get git info from working directory if available
        git_remote_url = None
        git_commit_hash = None
        working_dir = event_data.get("cwd")
        if working_dir:
            git_remote_url, git_commit_hash = get_git_info(Path(working_dir))

        # Insert to SQLite (synced_at = NULL, background worker will sync to API)
        event_id = self.sqlite_manager.insert_event(
            filename, line_number, event_data, git_remote_url, git_commit_hash
        )

        if event_id:
            # Build log message
            git_info = []
            if git_remote_url:
                repo_name = git_remote_url.split("/")[-1].replace(".git", "")
                git_info.append(f"repo:{repo_name}")
            if git_commit_hash:
                git_info.append(f"commit:{git_commit_hash[:7]}")

            status_msg = f"Stored: {filename}:{line_number}"
            if git_info:
                status_msg += f" [{', '.join(git_info)}]"
            logger.info(status_msg)
            return True

        return False

    def on_modified(self, event):
        """Handle file modification events."""
        if event.is_directory:
            return

        file_path = Path(event.src_path)
        if file_path.suffix == ".jsonl":
            logger.info(f"Detected change: {file_path.name}")
            self.process_file(file_path)

    def on_created(self, event):
        """Handle file creation events."""
        if event.is_directory:
            return

        file_path = Path(event.src_path)
        if file_path.suffix == ".jsonl":
            logger.info(f"Detected new file: {file_path.name}")
            self.process_file(file_path)

    # ===== Background Sync Worker =====

    def start_sync_worker(self):
        """Start the background sync worker thread."""
        if self.sync_thread and self.sync_thread.is_alive():
            logger.debug("Sync worker already running")
            return

        self.sync_running = True
        self.sync_thread = threading.Thread(target=self._sync_loop, daemon=True)
        self.sync_thread.start()
        logger.info("Background sync worker started")

    def stop_sync_worker(self):
        """Stop the background sync worker thread."""
        self.sync_running = False
        if self.sync_thread:
            self.sync_thread.join(timeout=5)
            logger.info("Background sync worker stopped")

    def _sync_loop(self):
        """Background loop that syncs pending events to the remote API."""
        while self.sync_running:
            try:
                if (
                    self.api_enabled
                    and self.sqlite_manager
                    and self.sqlite_manager.enabled
                ):
                    synced = self._sync_batch(batch_size=50)
                    if synced == 0:
                        # No pending events, sleep longer
                        time.sleep(60)
                    else:
                        # More to sync, short delay between batches
                        logger.info(f"Background sync: synced {synced} events")
                        time.sleep(2)
                else:
                    # API not enabled or SQLite not available, check periodically
                    time.sleep(60)
            except Exception as e:
                logger.error(f"Error in sync worker: {e}")
                # Back off on errors
                time.sleep(min(self.sync_backoff_delay * 2, 300))

    def _sync_batch(self, batch_size: int = 50) -> int:
        """Sync a batch of unsynced events to the remote API.

        Args:
            batch_size: Maximum number of events to sync in this batch.

        Returns:
            Number of events successfully synced.
        """
        if not self.sqlite_manager:
            return 0

        unsynced = self.sqlite_manager.get_unsynced_events(limit=batch_size)
        if not unsynced:
            return 0

        synced_count = 0
        for event in unsynced:
            try:
                # Create redacted version for remote API
                redacted_event_data = self.redact_secrets_from_event(
                    event["event_data"]
                )

                response = self.session.post(
                    f"{self.api_endpoint}/events",
                    json={
                        "file_name": event["file_name"],
                        "line_number": event["line_number"],
                        "event_data": redacted_event_data,
                        "git_remote_url": event["git_remote_url"],
                        "git_commit_hash": event["git_commit_hash"],
                    },
                )
                response.raise_for_status()

                # Mark as synced
                self.sqlite_manager.mark_event_synced(event["id"])
                synced_count += 1

                # Reset backoff on success
                self.sync_backoff_delay = 0.1

                # Throttle: 100ms between requests = 10 req/sec max
                time.sleep(0.1)

            except requests.RequestException as e:
                # On failure, stop batch and wait for next cycle
                logger.warning(f"Sync failed for event {event['id']}: {e}")
                # Exponential backoff, max 5 minutes
                self.sync_backoff_delay = min(self.sync_backoff_delay * 2, 300)
                break

        return synced_count

    def process_existing_files(self, directory: Path):
        """Process all existing JSONL files on startup."""
        logger.info("Processing existing files...")
        for file_path in directory.glob("**/*.jsonl"):
            self.process_file(file_path)
        logger.info("Finished processing existing files")


def is_mcp_plugin_installed() -> bool:
    """Check if vibe-check MCP server is registered in ~/.claude.json."""
    claude_config = Path.home() / ".claude.json"
    if not claude_config.exists():
        return False

    try:
        with open(claude_config, "r") as f:
            config = json.load(f)
        mcp_servers = config.get("mcpServers", {})
        return "vibe-check" in mcp_servers
    except (json.JSONDecodeError, IOError):
        return False


def install_mcp_server():
    """Install MCP server files and create virtualenv.

    Returns:
        Path to the MCP server directory, or None if installation failed
    """
    import shutil

    # Find source MCP server files
    # Check Homebrew location first
    homebrew_mcp = Path("/opt/homebrew/share/vibe-check/mcp-server")
    if homebrew_mcp.exists():
        mcp_source = homebrew_mcp
    else:
        # Check if we're in the vibe-check directory
        repo_mcp = Path(__file__).parent / "mcp-server"
        if repo_mcp.exists():
            mcp_source = repo_mcp
        else:
            logger.error("MCP server source files not found")
            return None

    # Install to ~/.vibe-check/mcp-server/
    mcp_dest = Path.home() / ".vibe-check" / "mcp-server"
    mcp_dest.parent.mkdir(parents=True, exist_ok=True)

    # Copy MCP server files
    try:
        if mcp_dest.exists():
            # Update existing installation
            for item in mcp_source.glob("*.py"):
                shutil.copy2(item, mcp_dest)
            # Copy requirements.txt if it exists
            req_file = mcp_source / "requirements.txt"
            if req_file.exists():
                shutil.copy2(req_file, mcp_dest)
        else:
            # Fresh install - copy everything except .venv
            shutil.copytree(
                mcp_source,
                mcp_dest,
                ignore=shutil.ignore_patterns('.venv', '__pycache__', '*.pyc')
            )
    except Exception as e:
        logger.error(f"Failed to copy MCP server files: {e}")
        return None

    # Create virtualenv at ~/.vibe-check/mcp-server/.venv
    venv_dir = mcp_dest / ".venv"
    if not venv_dir.exists():
        print("   Creating Python virtual environment...")
        try:
            subprocess.run(
                [sys.executable, "-m", "venv", str(venv_dir)],
                check=True,
                capture_output=True,
                text=True
            )
        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to create virtualenv: {e.stderr}")
            return None

    # Install MCP package
    pip_path = venv_dir / "bin" / "pip"
    if not pip_path.exists():
        logger.error(f"pip not found at {pip_path}")
        return None

    print("   Installing MCP dependencies...")
    try:
        # Upgrade pip
        subprocess.run(
            [str(pip_path), "install", "--quiet", "--upgrade", "pip"],
            check=True,
            capture_output=True
        )
        # Install mcp package
        subprocess.run(
            [str(pip_path), "install", "--quiet", "mcp"],
            check=True,
            capture_output=True
        )
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to install MCP dependencies: {e}")
        return None

    return mcp_dest


def register_mcp_in_claude_json(mcp_dir: Path):
    """Register MCP server in ~/.claude.json.

    Args:
        mcp_dir: Path to the MCP server directory

    Returns:
        True if successful, False otherwise
    """
    claude_json = Path.home() / ".claude.json"
    venv_python = mcp_dir / ".venv" / "bin" / "python"
    server_py = mcp_dir / "server.py"

    # Ensure files exist
    if not venv_python.exists() or not server_py.exists():
        logger.error(f"MCP server files not found: {venv_python} or {server_py}")
        return False

    # Create or update ~/.claude.json
    if claude_json.exists():
        try:
            with open(claude_json, "r") as f:
                config = json.load(f)
        except (json.JSONDecodeError, IOError) as e:
            logger.error(f"Failed to read {claude_json}: {e}")
            return False
    else:
        config = {}

    # Ensure mcpServers section exists
    if "mcpServers" not in config:
        config["mcpServers"] = {}

    # Add/update vibe-check MCP server
    config["mcpServers"]["vibe-check"] = {
        "type": "stdio",
        "command": str(venv_python),
        "args": [str(server_py)],
        "env": {
            "VIBE_CHECK_DB": str(Path.home() / ".vibe-check" / "vibe_check.db"),
            "VIBE_CHECK_CONFIG": str(Path.home() / ".vibe-check" / "config.json")
        }
    }

    # Write back to file
    try:
        with open(claude_json, "w") as f:
            json.dump(config, f, indent=2)
        return True
    except IOError as e:
        logger.error(f"Failed to write {claude_json}: {e}")
        return False


def check_mcp_plugin(interactive: bool = True):
    """Check if MCP plugin is installed and auto-install if not.

    The MCP plugin provides structured tool interfaces for Claude Code,
    enabling commands like /stats, /search, /share etc.

    Args:
        interactive: If False, install silently without banner
    """
    if is_mcp_plugin_installed():
        return  # Already installed

    # Show banner only if interactive
    if interactive:
        print("\n" + "=" * 70)
        print("🔌 Installing Claude Code MCP Plugin...")
        print("=" * 70)
        print("\nThis enables structured commands like /stats, /search, /share")
        print("and natural language queries about your conversation history.\n")

    try:
        # Step 1: Install MCP server files and create virtualenv
        mcp_dir = install_mcp_server()
        if not mcp_dir:
            if interactive:
                print("\n⚠️  Failed to install MCP server files")
            return

        # Step 2: Register in ~/.claude.json
        print("   Registering MCP server in Claude Code...")
        if not register_mcp_in_claude_json(mcp_dir):
            if interactive:
                print("\n⚠️  Failed to register MCP server in ~/.claude.json")
            return

        # Step 3: Install skills (reuse existing logic)
        check_claude_skills()

        if interactive:
            print("\n✅ MCP plugin installed successfully!")
            print("   Restart Claude Code to use the new commands.")
            print("=" * 70)
            print()
        else:
            logger.info("MCP plugin installed successfully")

    except Exception as e:
        logger.warning(f"Could not install MCP plugin: {e}")
        if interactive:
            print(f"\n⚠️  Could not install MCP plugin: {e}")
            print("=" * 70)
            print()


def check_claude_skills(interactive=True):
    """Check if Claude Code skills are installed and prompt to install if not.

    Args:
        interactive: If False, auto-install without prompting
    """
    skills_dir = Path.home() / ".claude" / "skills"

    # Discover available skills from Homebrew or repo location
    homebrew_skills_dir = Path("/opt/homebrew/share/vibe-check/skills")
    repo_skills_dir = Path(__file__).parent / "skills"

    # Find which skills source is available
    skills_source_dir = None
    if homebrew_skills_dir.exists():
        skills_source_dir = homebrew_skills_dir
    elif repo_skills_dir.exists():
        skills_source_dir = repo_skills_dir

    if not skills_source_dir:
        # No skills to check
        return

    # Dynamically discover all vibe-check-* skill directories
    skills_to_check = [
        d.name for d in skills_source_dir.glob("vibe-check-*")
        if d.is_dir() and (d / "SKILL.md").exists()
    ]

    if not skills_to_check:
        # No skills found
        return

    # Check if any skills are missing (check for SKILL.md inside directory)
    missing_skills = []
    for skill in skills_to_check:
        skill_file = skills_dir / skill / "SKILL.md"
        if not skill_file.exists():
            missing_skills.append(skill)

    # If all skills are installed, nothing to do
    if not missing_skills:
        return

    # First, try Homebrew location (auto-install silently)
    homebrew_skills_dir = Path("/opt/homebrew/share/vibe-check/skills")
    if homebrew_skills_dir.exists():
        import shutil

        skills_dir.mkdir(parents=True, exist_ok=True)
        installed_count = 0
        updated_count = 0
        # Copy skill directories (new structure: vibe-check-*/SKILL.md)
        for skill_src_dir in homebrew_skills_dir.glob("vibe-check-*"):
            if skill_src_dir.is_dir():
                dest = skills_dir / skill_src_dir.name
                try:
                    if dest.exists():
                        # Update existing skill
                        shutil.rmtree(dest)
                        shutil.copytree(skill_src_dir, dest)
                        updated_count += 1
                    else:
                        # Install new skill
                        shutil.copytree(skill_src_dir, dest)
                        installed_count += 1
                except Exception as e:
                    logger.warning(
                        f"Could not install/update skill {skill_src_dir.name}: {e}"
                    )
        if installed_count > 0 or updated_count > 0:
            logger.info(
                f"Installed {installed_count} new skills, updated {updated_count} existing skills to {skills_dir}"
            )
        return

    # Non-interactive mode: auto-install by copying skills directly
    if not interactive:
        import shutil
        skills_dir.mkdir(parents=True, exist_ok=True)
        # Copy skills from repo/installation location
        script_dir = Path(__file__).parent
        repo_skills_dir = script_dir / "skills"
        if repo_skills_dir.exists():
            installed_count = 0
            for skill_src_dir in repo_skills_dir.glob("vibe-check-*"):
                if skill_src_dir.is_dir() and (skill_src_dir / "SKILL.md").exists():
                    dest = skills_dir / skill_src_dir.name
                    try:
                        if dest.exists():
                            shutil.rmtree(dest)
                        shutil.copytree(skill_src_dir, dest)
                        installed_count += 1
                        logger.debug(f"Installed skill: {skill_src_dir.name}")
                    except Exception as e:
                        logger.warning(f"Could not install skill {skill_src_dir.name}: {e}")
            if installed_count > 0:
                logger.info(f"Installed {installed_count} skills to {skills_dir}")
            else:
                logger.warning(f"No skills found in {repo_skills_dir}")
        else:
            logger.warning(f"Skills directory not found: {repo_skills_dir}")
        return

    # Interactive mode: check if installer script is available
    script_dir = Path(__file__).parent
    installer_path = script_dir / "scripts" / "install-plugin.sh"

    if not installer_path.exists():
        # Installer not available - can't do interactive installation
        logger.debug("Skills installer not found, skipping interactive prompt")
        return

    # Skills are missing and installer is available - prompt user
    print("\n" + "=" * 70)
    print("📚 Claude Code Skills Available!")
    print("=" * 70)
    print("\nVibe Check includes Claude Code skills that let you query your")
    print("conversation history using natural language!")
    print(f"\nMissing skills: {len(missing_skills)}/{len(skills_to_check)}")
    print("\nOnce installed, you can ask Claude:")
    print("  • 'claude stats' - View usage statistics")
    print("  • 'what have I been working on?' - See recent sessions")
    print("  • 'search my conversations for X' - Search history")
    print("  • 'what tools do I use most?' - Analyze tool usage")
    print("  • 'vibe stats' - Open your stats page in browser")
    print("\nWould you like to install the skills now? (y/n): ", end="", flush=True)

    try:
        response = input().strip().lower()
        if response in ["y", "yes"]:
            print("\nInstalling skills...")
            result = subprocess.run(
                [str(installer_path)], cwd=str(script_dir), capture_output=False
            )
            if result.returncode == 0:
                print("\n✅ Skills installed successfully!")
            else:
                print(
                    "\n⚠️  Installation had some issues. You can install manually later:"
                )
                print(f"   {installer_path}")
        else:
            print("\nSkipped. You can install skills later by running:")
            print(f"  {installer_path}")
    except (EOFError, KeyboardInterrupt):
        print("\n\nSkipped. You can install skills later by running:")
        print(f"  {installer_path}")

    print("=" * 70)
    print()


def update_global_git_hooks_if_needed():
    """Auto-update global git hooks to latest version if configured.

    This runs silently on startup. If global git hooks are configured
    (git config --global core.hooksPath), validates that symlinks point
    to the current installation and updates them if needed.

    Only prints a message if an update was actually performed.
    """
    try:
        # Check if global hooks are configured
        hooks_path = subprocess.run(
            ["git", "config", "--global", "--get", "core.hooksPath"],
            capture_output=True,
            text=True,
            check=False
        ).stdout.strip()

        if not hooks_path:
            # Global hooks not configured, nothing to do
            return

        global_hooks_dir = Path(hooks_path).expanduser()

        # Only auto-update if it's the vibe-check hooks directory
        if not (global_hooks_dir == Path.home() / ".vibe-check" / "git-hooks"):
            return

        if not global_hooks_dir.exists():
            # Hooks directory doesn't exist, skip
            return

        # Find current installation's hook sources
        script_dir = Path(__file__).parent / "scripts"
        source_hooks = {
            "prepare-commit-msg": script_dir / "prepare-commit-msg",
            "post-commit": script_dir / "post-commit"
        }

        # Check if any hooks need updating
        needs_update = False
        for hook_name, source_hook in source_hooks.items():
            if not source_hook.exists():
                continue

            target_hook = global_hooks_dir / hook_name

            # Check if hook is missing, broken, or points to wrong location
            if not target_hook.exists():
                needs_update = True
                break

            if target_hook.is_symlink():
                resolved = target_hook.resolve()
                if resolved != source_hook.resolve():
                    # Symlink points to different location (old installation)
                    needs_update = True
                    break
            else:
                # Not a symlink - could be outdated copy
                needs_update = True
                break

        if not needs_update:
            # All hooks are up to date
            return

        # Update hooks
        updated_hooks = []
        for hook_name, source_hook in source_hooks.items():
            if not source_hook.exists():
                continue

            target_hook = global_hooks_dir / hook_name

            # Remove existing hook (file or symlink)
            if target_hook.exists() or target_hook.is_symlink():
                target_hook.unlink()

            # Create fresh symlink
            target_hook.symlink_to(source_hook)
            target_hook.chmod(0o755)
            updated_hooks.append(hook_name)

        if updated_hooks:
            logger.info(f"✓ Updated global git hooks to latest version ({', '.join(updated_hooks)})")

    except Exception as e:
        # Silent failure - don't interrupt startup for hook updates
        logger.debug(f"Failed to auto-update global git hooks: {e}")


def check_git_hooks(interactive=True):
    """Check if git hooks are installed and prompt to install if not.

    Offers global installation (all repos) or local installation (current repo).
    Only prompts if install script is available.

    Args:
        interactive: If False, install globally without prompting
    """
    # Check if install script is available
    script_dir = Path(__file__).parent
    install_script = script_dir / "scripts" / "install-git-hook.sh"

    if not install_script.exists():
        # Installer not available
        return

    # Check global hooks status
    git_status = check_git_hooks_status()
    global_configured = git_status["global_configured"]
    global_hooks = git_status.get("global_hooks", {})

    # Check if we're in a git repo for local hooks
    cwd = Path.cwd()
    hooks_dir = cwd / ".git" / "hooks"
    in_git_repo = hooks_dir.exists()

    # Determine if anything needs to be installed
    global_needs_install = not global_configured or not all(
        status == "installed" for status in global_hooks.values()
    )

    local_needs_install = False
    if in_git_repo:
        cwd_hooks = git_status.get("cwd_hooks", {})
        local_needs_install = not all(
            status in ("installed", "installed_chained")
            for status in cwd_hooks.values()
        )

    # If everything is installed, nothing to do
    if not global_needs_install and not local_needs_install:
        return

    # Non-interactive mode: install globally by default
    if not interactive:
        if global_needs_install:
            args = type('Args', (), {'global_install': True, 'no_notes': False, 'path': None})()
            cmd_git_install(args)
        return

    # Hooks are missing - prompt user
    print("\n" + "=" * 70)
    print("🔗 Git Integration Available!")
    print("=" * 70)
    print("\nVibe Check can enhance your git workflow by:")
    print("  1. Adding Claude session links to commit messages")
    print("  2. Attaching full conversation transcripts as git notes")
    print()

    # Show global status
    print("Global hooks (all repos):")
    if global_configured and global_hooks:
        prepare_installed = global_hooks.get("prepare-commit-msg") == "installed"
        post_installed = global_hooks.get("post-commit") == "installed"

        if prepare_installed:
            print("  ✅ Commit message enhancement: Installed")
        else:
            print("  ❌ Commit message enhancement: Not installed")

        if post_installed:
            print("  ✅ Git notes (transcripts):    Installed")
        else:
            print("  ❌ Git notes (transcripts):    Not installed")
    else:
        print("  ❌ Not configured")

    # Show local status if in a git repo
    if in_git_repo:
        print(f"\nCurrent repo ({cwd.name}):")
        cwd_hooks = git_status.get("cwd_hooks", {})
        prepare_status = cwd_hooks.get("prepare-commit-msg", "not_installed")
        post_status = cwd_hooks.get("post-commit", "not_installed")

        if prepare_status in ("installed", "installed_chained"):
            status_text = "Installed (chained)" if prepare_status == "installed_chained" else "Installed"
            print(f"  ✅ Commit message enhancement: {status_text}")
        else:
            print("  ❌ Commit message enhancement: Not installed")

        if post_status in ("installed", "installed_chained"):
            status_text = "Installed (chained)" if post_status == "installed_chained" else "Installed"
            print(f"  ✅ Git notes (transcripts):    {status_text}")
        else:
            print("  ❌ Git notes (transcripts):    Not installed")

    print()
    print("Would you like to install git hooks?")
    if global_needs_install:
        print("  [g] Global (all repos) - Recommended")
    if in_git_repo and local_needs_install:
        print("  [c] Current repo only")
    if global_needs_install and in_git_repo and local_needs_install:
        print("  [b] Both (global + current repo)")
    print("  [n] No / Skip")
    print()
    print("Choice: ", end="", flush=True)

    try:
        response = input().strip().lower()

        install_global = False
        install_local = False

        if response == "g" and global_needs_install:
            install_global = True
        elif response == "c" and in_git_repo and local_needs_install:
            install_local = True
        elif response == "b" and global_needs_install and in_git_repo and local_needs_install:
            install_global = True
            install_local = True
        elif response in ["n", "no", ""]:
            print("\nSkipped. You can install git hooks later with:")
            print("  vibe-check git install [--global]")
            print("=" * 70)
            print()
            return
        else:
            print("\nInvalid choice. Skipping installation.")
            print("=" * 70)
            print()
            return

        # Install global hooks
        if install_global:
            print("\nInstalling global git hooks...")
            result = subprocess.run(
                [str(install_script), "--global"],
                cwd=str(script_dir),
                capture_output=False
            )
            if result.returncode == 0:
                print("✅ Global git hooks installed!")

        # Install local hooks
        if install_local:
            print("\nInstalling git hooks to current repository...")
            result = subprocess.run(
                [str(install_script), str(cwd)],
                cwd=str(script_dir),
                capture_output=False
            )
            if result.returncode == 0:
                print("✅ Local git hooks installed!")

        print("\n" + "=" * 70)
        print()

    except (EOFError, KeyboardInterrupt):
        print("\n\nSkipped. You can install git hooks later with:")
        print("  vibe-check git install [--global]")
        print("=" * 70)
        print()


def get_data_dir() -> Path:
    """Get the data directory path.

    Always uses ~/.vibe-check/ for all installation types.
    Homebrew installs symlink /opt/homebrew/var/vibe-check -> ~/.vibe-check
    """
    return Path.home() / ".vibe-check"


def get_pid_file() -> Path:
    """Get the path to the PID file."""
    return get_data_dir() / ".monitor.pid"


def get_log_file() -> Path:
    """Get the path to the log file (for daemon mode)."""
    return get_data_dir() / "monitor.log"


def is_brew_service_running() -> bool:
    """Check if vibe-check is running as a Homebrew service."""
    try:
        result = subprocess.run(
            ["brew", "services", "list"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                if "vibe-check" in line and "started" in line.lower():
                    return True
    except FileNotFoundError:
        pass
    return False


def get_brew_log_dir() -> Path:
    """Get the Homebrew log directory."""
    return Path("/opt/homebrew/var/log")


def get_active_log_paths() -> list[tuple[Path, str]]:
    """Get the active log file paths based on how vibe-check is running.

    Returns a list of (path, description) tuples.
    """
    logs = []

    # Check if running as brew service
    if is_brew_service_running():
        brew_log_dir = get_brew_log_dir()
        # Unified log (stdout + stderr go to same file as of v1.1.6)
        unified_log = brew_log_dir / "vibe-check.log"
        if unified_log.exists():
            logs.append((unified_log, ""))

        # Check for legacy error log (separate file from before v1.1.6)
        legacy_error_log = brew_log_dir / "vibe-check.error.log"
        if legacy_error_log.exists():
            logs.append((legacy_error_log, "⚠️  stale, safe to delete"))

    # Check daemon mode log
    daemon_log = get_log_file()
    if daemon_log.exists():
        if is_brew_service_running():
            # Stale log from old daemon runs before switching to Homebrew
            logs.append((daemon_log, "⚠️  stale, safe to delete"))
        else:
            logs.append((daemon_log, ""))

    # If nothing found, return expected paths
    if not logs:
        if is_brew_service_running():
            logs.append(
                (
                    get_brew_log_dir() / "vibe-check.log",
                    "(not created yet)",
                )
            )
        else:
            logs.append((get_log_file(), "(not created yet)"))

    return logs


def is_running() -> Optional[int]:
    """Check if monitor is already running. Returns PID if running, None otherwise.

    Checks both PID file (for manual daemon mode) and process list (for brew services).
    """
    # First check PID file (for manual daemon mode)
    pid_file = get_pid_file()
    if pid_file.exists():
        try:
            with open(pid_file, "r") as f:
                pid = int(f.read().strip())

            # Check if process is actually running
            try:
                os.kill(pid, 0)  # Signal 0 just checks if process exists
                return pid
            except OSError:
                # Process doesn't exist, clean up stale PID file
                pid_file.unlink()
        except (ValueError, FileNotFoundError):
            pass

    # Fallback: check if any vibe-check.py process is running (for brew services mode)
    # Exclude: current process, parent process, and any process running start/stop/status/etc commands
    try:
        current_pid = os.getpid()
        parent_pid = os.getppid()

        # Use ps to get both PID and full command line
        result = subprocess.run(
            ["ps", "ax", "-o", "pid,args"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            for line in result.stdout.strip().split("\n"):
                if "vibe-check.py" not in line:
                    continue
                parts = line.strip().split(None, 1)
                if len(parts) < 2:
                    continue
                try:
                    pid = int(parts[0])
                    cmdline = parts[1]
                except ValueError:
                    continue
                # Skip our own process and parent
                if pid in (current_pid, parent_pid):
                    continue
                # Skip if it's running a subcommand (start, stop, status, etc.)
                if any(
                    cmd in cmdline
                    for cmd in [
                        " start",
                        " stop",
                        " status",
                        " restart",
                        " logs",
                        " auth",
                    ]
                ):
                    continue
                return pid
    except Exception:
        pass

    return None


def is_homebrew_service() -> bool:
    """Check if vibe-check is installed via Homebrew and the service is available."""
    try:
        result = subprocess.run(
            ["brew", "services", "list"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and "vibe-check" in result.stdout:
            return True
    except FileNotFoundError:
        # brew command not found, not a brew installation
        pass
    return False


def is_homebrew_service_running() -> bool:
    """Check if vibe-check is currently running as a Homebrew service."""
    try:
        result = subprocess.run(
            ["brew", "services", "list"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                if "vibe-check" in line and "started" in line.lower():
                    return True
    except FileNotFoundError:
        pass
    return False


def is_systemd_service() -> bool:
    """Check if vibe-check is installed as a systemd user service."""
    service_file = Path.home() / ".config" / "systemd" / "user" / "vibe-check.service"
    return service_file.exists()


def is_systemd_service_running() -> bool:
    """Check if vibe-check is currently running as a systemd service."""
    try:
        result = subprocess.run(
            ["systemctl", "--user", "is-active", "vibe-check"],
            capture_output=True,
            text=True,
        )
        return result.stdout.strip() == "active"
    except FileNotFoundError:
        pass
    return False


def create_macos_service() -> bool:
    """Create macOS LaunchAgent plist for auto-start.

    Returns:
        True if service created successfully, False otherwise
    """
    # Skip if Homebrew (it manages its own service)
    if is_homebrew_service():
        return True

    plist_path = Path.home() / "Library/LaunchAgents/com.vibecheck.monitor.plist"

    # Find vibe-check wrapper script
    script_dir = Path(__file__).parent
    wrapper = script_dir / "vibe-check"

    if not wrapper.exists():
        # Try installed location
        wrapper = Path.home() / ".vibe-check/vibe-check"

    if not wrapper.exists():
        logger.error("Cannot find vibe-check wrapper script")
        return False

    plist_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.vibecheck.monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>{wrapper}</string>
        <string>start</string>
        <string>--foreground</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{Path.home()}/.vibe-check/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>{Path.home()}/.vibe-check/launchd.error.log</string>
</dict>
</plist>"""

    try:
        plist_path.parent.mkdir(parents=True, exist_ok=True)
        with open(plist_path, 'w') as f:
            f.write(plist_content)

        # Load the service
        result = subprocess.run(
            ["launchctl", "load", str(plist_path)],
            capture_output=True,
            text=True
        )

        if result.returncode == 0:
            print(f"   ✅ LaunchAgent installed: {plist_path}")
            print("      Service will start automatically on boot")
            return True
        else:
            logger.error(f"Failed to load LaunchAgent: {result.stderr}")
            return False

    except Exception as e:
        logger.error(f"Failed to create LaunchAgent: {e}")
        return False


def create_linux_service() -> bool:
    """Create systemd user service for auto-start.

    Returns:
        True if service created successfully, False otherwise
    """
    # Check if systemd is available
    try:
        result = subprocess.run(
            ["systemctl", "--user", "--version"],
            capture_output=True,
            check=False
        )
        if result.returncode != 0:
            logger.warning("systemd user services not available")
            return False
    except FileNotFoundError:
        logger.warning("systemctl not found")
        return False

    service_path = Path.home() / ".config/systemd/user/vibe-check.service"

    # Find vibe-check wrapper
    script_dir = Path(__file__).parent
    wrapper = script_dir / "vibe-check"

    if not wrapper.exists():
        wrapper = Path.home() / ".vibe-check/vibe-check"

    if not wrapper.exists():
        logger.error("Cannot find vibe-check wrapper script")
        return False

    service_content = f"""[Unit]
Description=Vibe Check - Claude Code Monitor
After=network.target

[Service]
Type=simple
ExecStart={wrapper} start --foreground
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target"""

    try:
        service_path.parent.mkdir(parents=True, exist_ok=True)
        with open(service_path, 'w') as f:
            f.write(service_content)

        # Reload, enable, and start
        subprocess.run(["systemctl", "--user", "daemon-reload"], check=False)
        subprocess.run(["systemctl", "--user", "enable", "vibe-check"], check=False)
        result = subprocess.run(
            ["systemctl", "--user", "start", "vibe-check"],
            capture_output=True,
            text=True,
            check=False
        )

        # Verify it started
        time.sleep(1)
        verify = subprocess.run(
            ["systemctl", "--user", "is-active", "vibe-check"],
            capture_output=True,
            text=True,
            check=False
        )

        if verify.stdout.strip() == "active":
            print(f"   ✅ Systemd service installed: {service_path}")
            print("      Service will start automatically on boot")
            return True
        else:
            logger.warning("systemd service created but not active")
            print(f"   ⚠️  Service created: {service_path}")
            print("      May need manual start: systemctl --user start vibe-check")
            return False

    except Exception as e:
        logger.error(f"Failed to create systemd service: {e}")
        return False


def register_service() -> bool:
    """Register vibe-check as a system service (LaunchAgent or systemd).

    Detects platform and creates appropriate service configuration.
    Skips if Homebrew service is available (managed by brew services).

    Returns:
        True if service registered successfully, False otherwise
    """
    # Skip if Homebrew (it manages services)
    if is_homebrew_service():
        print("   ✅ Service managed by Homebrew (use: brew services start vibe-check)")
        return True

    # Skip if service already exists
    system = platform.system()
    if system == "Darwin":
        plist_path = Path.home() / "Library/LaunchAgents/com.vibecheck.monitor.plist"
        if plist_path.exists():
            print(f"   ✅ LaunchAgent already installed: {plist_path}")
            return True
    elif system == "Linux":
        service_path = Path.home() / ".config/systemd/user/vibe-check.service"
        if service_path.exists():
            print(f"   ✅ Systemd service already installed: {service_path}")
            return True

    print("   ⚙️  Registering vibe-check service...")

    if system == "Darwin":
        return create_macos_service()
    elif system == "Linux":
        return create_linux_service()
    else:
        print(f"   ⚠️  Automatic service registration not supported on {system}")
        print("      The daemon will need to be started manually: vibe-check start")
        return False


def write_pid_file():
    """Write current process PID to file."""
    pid_file = get_pid_file()
    pid_file.parent.mkdir(parents=True, exist_ok=True)
    with open(pid_file, "w") as f:
        f.write(str(os.getpid()))


def remove_pid_file():
    """Remove PID file."""
    pid_file = get_pid_file()
    if pid_file.exists():
        pid_file.unlink()


def daemonize():
    """Daemonize the process."""
    # Fork once
    try:
        pid = os.fork()
        if pid > 0:
            # Parent exits
            sys.exit(0)
    except OSError as e:
        print(f"Fork failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Decouple from parent environment
    os.chdir("/")
    os.setsid()
    os.umask(0)

    # Fork again
    try:
        pid = os.fork()
        if pid > 0:
            # Parent exits
            sys.exit(0)
    except OSError as e:
        print(f"Fork failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Redirect standard file descriptors
    sys.stdout.flush()
    sys.stderr.flush()

    # Set up logging to file for daemon mode
    log_file = get_log_file()
    setup_logging(log_file)

    # Close stdin
    with open("/dev/null", "r") as f:
        os.dup2(f.fileno(), sys.stdin.fileno())


def cmd_start(args):
    """Start the monitor in daemon mode (or foreground with --foreground)."""
    pid = is_running()
    if pid:
        print(f"✅ Monitor is already running (PID: {pid})")
        return

    # Check if authenticated, offer to login on first start (unless skip_auth_check is set)
    skip_auth_check = getattr(args, 'skip_auth_check', False)

    if not skip_auth_check:
        config_path = get_config_path()
        needs_auth_prompt = False

        if config_path.exists():
            try:
                with open(config_path, "r") as f:
                    config = json.load(f)
                api_key = config.get("api", {}).get("api_key", "")
                if not api_key:
                    needs_auth_prompt = True
            except (json.JSONDecodeError, IOError):
                needs_auth_prompt = True
        else:
            needs_auth_prompt = True

        if needs_auth_prompt:
            print("\n☁️  Remote Logging Configuration")
            print("   ═══════════════════════════════")
            print("   Vibe Check can optionally sync your Claude Code conversations")
            print("   to a remote server for web-based viewing and sharing.")
            print()
            print("   • All conversations are stored locally in SQLite")
            print("   • Remote sync is optional and can be enabled later")
            print()
            print("Enable remote logging? (y/N): ", end="", flush=True)
            try:
                response = input().strip().lower()
                if response in ["y", "yes"]:  # Opt-in (default to NO)
                    cmd_auth_login(args)
                    print()  # blank line after auth
                else:
                    print("\n✓ Skipping remote logging - local-only mode")
                    print("  You can enable remote sync later with: vibe-check auth login")
            except (EOFError, KeyboardInterrupt):
                print("\n✓ Skipping remote logging - local-only mode")
                print("  You can enable remote sync later with: vibe-check auth login")

    # Check and auto-install MCP plugin if not present
    check_mcp_plugin()

    # If homebrew install and not forcing foreground, use brew services
    if is_homebrew_service() and not getattr(args, "foreground", False):
        print("🧜 Starting via Homebrew service...")
        result = subprocess.run(["brew", "services", "start", "vibe-check"])
        if result.returncode == 0:
            print("✅ vibe-check service started (auto-starts on boot)\n")
            # Wait for service to start, then show status
            time.sleep(2)
            cmd_status(args)
        else:
            print("❌ Failed to start Homebrew service")
        return

    # If systemd install and not forcing foreground, use systemctl
    if is_systemd_service() and not getattr(args, "foreground", False):
        print("🐧 Starting via systemd service...")
        result = subprocess.run(["systemctl", "--user", "start", "vibe-check"])
        if result.returncode == 0:
            print("✅ vibe-check service started\n")
            # Wait for service to start, then show status
            time.sleep(2)
            cmd_status(args)
        else:
            print("❌ Failed to start systemd service")
        return

    # Set up signal handlers
    def signal_handler(signum, frame):
        logger.info(f"Received signal {signum}, stopping monitor...")
        remove_pid_file()
        sys.exit(0)

    if getattr(args, "foreground", False):
        # Foreground mode for systemd/launchd
        print("🧜 Starting monitor in foreground...")

        # Set up logging to stdout for foreground mode
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s - %(levelname)s - %(message)s",
            handlers=[logging.StreamHandler(sys.stdout)],
        )

        write_pid_file()
        signal.signal(signal.SIGTERM, signal_handler)
        signal.signal(signal.SIGINT, signal_handler)

        logger.info("Monitor started (foreground mode)")
        run_monitor(args)
    else:
        # Background/daemon mode (non-homebrew install)
        print("🧜 Starting monitor in background...")

        # Daemonize the process
        daemonize()

        # Write PID file
        write_pid_file()

        signal.signal(signal.SIGTERM, signal_handler)
        signal.signal(signal.SIGINT, signal_handler)

        # Run the monitor (logging is already set up by daemonize())
        logger.info("Monitor started")
        run_monitor(args)


def cmd_stop(args):
    """Stop the monitor daemon."""
    # Check if running as a brew service first
    if is_homebrew_service_running():
        print("🧜 Stopping Homebrew service...")
        result = subprocess.run(["brew", "services", "stop", "vibe-check"])
        if result.returncode == 0:
            print("✅ vibe-check service stopped (auto-start disabled)")
        else:
            print("❌ Failed to stop Homebrew service")
        return

    # Check if running as a systemd service
    if is_systemd_service_running():
        print("🐧 Stopping systemd service...")
        result = subprocess.run(["systemctl", "--user", "stop", "vibe-check"])
        if result.returncode == 0:
            print("✅ vibe-check service stopped")
        else:
            print("❌ Failed to stop systemd service")
        return

    pid = is_running()
    if not pid:
        print("⚠️  Monitor is not running")
        return

    print(f"🧜 Stopping monitor (PID: {pid})...")

    try:
        # Send SIGTERM
        os.kill(pid, signal.SIGTERM)

        # Wait up to 5 seconds for graceful shutdown
        for _ in range(50):
            time.sleep(0.1)
            try:
                os.kill(pid, 0)
            except OSError:
                # Process has exited
                break
        else:
            # Still running, force kill
            print("⚠️  Force killing vibe-check process...")
            os.kill(pid, signal.SIGKILL)
            time.sleep(0.5)

        remove_pid_file()
        print(f"✅ vibe-check process {pid} stopped")
    except OSError as e:
        print(f"Error stopping vibe-check process: {e}")
        remove_pid_file()


def cmd_restart(args):
    """Restart the vibe-check process daemon."""
    # If homebrew service, use brew services restart directly
    if is_homebrew_service_running() or is_homebrew_service():
        print("🧜 Restarting Homebrew service...")
        result = subprocess.run(["brew", "services", "restart", "vibe-check"])
        if result.returncode == 0:
            print("✅ vibe-check service restarted")
        else:
            print("❌ Failed to restart Homebrew service")
        return

    # If systemd service, use systemctl restart
    if is_systemd_service_running() or is_systemd_service():
        print("🐧 Restarting systemd service...")
        result = subprocess.run(["systemctl", "--user", "restart", "vibe-check"])
        if result.returncode == 0:
            print("✅ vibe-check service restarted")
        else:
            print("❌ Failed to restart systemd service")
        return

    cmd_stop(args)
    time.sleep(1)
    cmd_start(args)


def get_config_path() -> Path:
    """Get the path to the config file."""
    return get_data_dir() / "config.json"


def get_state_file_path() -> Path:
    """Get the path to the state file."""
    return get_data_dir() / "state.json"


def get_sqlite_db_path() -> Optional[Path]:
    """Get the path to the SQLite database from config."""
    config_path = get_config_path()
    if config_path.exists():
        try:
            with open(config_path, "r") as f:
                config = json.load(f)

            # Handle configs missing sqlite section (created before sqlite support)
            if "sqlite" not in config:
                # Use default path - ~/.vibe-check/vibe_check.db
                default_path = Path.home() / ".vibe-check" / "vibe_check.db"
                if default_path.exists():
                    return default_path
                # Also check data dir (manual installs)
                data_dir_path = get_data_dir() / "vibe_check.db"
                if data_dir_path.exists():
                    return data_dir_path
                return None

            if config["sqlite"].get("enabled", True):
                return Path(config["sqlite"]["database_path"]).expanduser()
        except (json.JSONDecodeError, KeyError):
            pass
    return None


def check_git_hooks_status() -> dict:
    """
    Check the status of git hooks (global and current repo).

    Returns dict with:
        - global_configured: bool, whether global hooks path is set
        - global_hooks_dir: Path to global hooks directory (if configured)
        - global_hooks: dict of global hooks status
        - cwd_hooks: dict of hooks found in current directory (if git repo)
        - install_script: path to install script if available
    """
    result = {
        "global_configured": False,
        "global_hooks_dir": None,
        "global_hooks": {},
        "cwd_hooks": {},
        "install_script": None
    }

    # Check global git hooks configuration
    try:
        hooks_path = subprocess.run(
            ["git", "config", "--global", "--get", "core.hooksPath"],
            capture_output=True,
            text=True,
            check=False
        ).stdout.strip()

        if hooks_path:
            global_hooks_dir = Path(hooks_path).expanduser()
            result["global_configured"] = True
            result["global_hooks_dir"] = global_hooks_dir

            if global_hooks_dir.exists():
                # Check global prepare-commit-msg
                prepare_hook = global_hooks_dir / "prepare-commit-msg"
                if prepare_hook.exists() and (
                    (prepare_hook.is_symlink() and "vibe-check" in str(prepare_hook.resolve()))
                    or not prepare_hook.is_symlink()
                ):
                    result["global_hooks"]["prepare-commit-msg"] = "installed"
                else:
                    result["global_hooks"]["prepare-commit-msg"] = "not_installed"

                # Check global post-commit
                post_hook = global_hooks_dir / "post-commit"
                if post_hook.exists() and (
                    (post_hook.is_symlink() and "vibe-check" in str(post_hook.resolve()))
                    or not post_hook.is_symlink()
                ):
                    result["global_hooks"]["post-commit"] = "installed"
                else:
                    result["global_hooks"]["post-commit"] = "not_installed"
    except Exception:
        pass

    # Check if current directory is a git repo
    cwd = Path.cwd()
    hooks_dir = cwd / ".git" / "hooks"

    if hooks_dir.exists():
        def check_hook(hook_path):
            """Check hook status with chaining detection."""
            if not hook_path.exists():
                return "not_installed"
            if hook_path.is_symlink():
                target = hook_path.resolve()
                if "vibe-check" in str(target):
                    # Check for chained hook
                    local_hook = hook_path.with_suffix('.local')
                    if local_hook.exists():
                        return "installed_chained"
                    return "installed"
                else:
                    return "other"
            else:
                return "other"

        result["cwd_hooks"]["prepare-commit-msg"] = check_hook(hooks_dir / "prepare-commit-msg")
        result["cwd_hooks"]["post-commit"] = check_hook(hooks_dir / "post-commit")

    # Check if install script is available
    install_dir = Path(__file__).parent
    install_script = install_dir / "scripts" / "install-git-hook.sh"
    if install_script.exists():
        result["install_script"] = install_script

    return result


def cmd_status(args):
    """Check vibe-check process status."""
    print(f"\033[1m🧜 vibe-check v{VERSION}\033[0m")
    print("")

    pid = is_running()
    is_brew_service = is_homebrew_service_running()
    is_systemd = is_systemd_service_running()

    print("🚀 Service status:")
    if pid:
        print(f"   ✅ Running (PID: {pid})")

        # Determine mode and auto-start status
        if is_brew_service:
            print("   Mode:       Homebrew service")
            print("   Auto-start: ✅ on boot")
        elif is_systemd:
            print("   Mode:       systemd service")
            print("   Auto-start: ✅ on login")
        else:
            print("   Mode:       daemon")
            if is_homebrew_service():
                print("   Auto-start: ❌ disabled (use 'brew services start vibe-check')")
            elif is_systemd_service():
                print("   Auto-start: ❌ disabled (use 'systemctl --user enable vibe-check')")
            else:
                print("   Auto-start: ❌ disabled")

        # Get uptime from ps
        try:
            result = subprocess.run(
                ["ps", "-p", str(pid), "-o", "etime="],
                capture_output=True,
                text=True,
            )
            if result.returncode == 0 and result.stdout.strip():
                print(f"   Uptime:     {result.stdout.strip()}")
        except Exception:
            pass
    else:
        print("   ❌ Not running")
        print("   To start:   vibe-check start")

    # Show file locations
    print("\n📁 File locations:")

    # Config file (resolve symlinks to show true location)
    config_path = get_config_path()
    if config_path.exists():
        print(f"   Config:   {config_path.resolve()}")
    else:
        print(f"   Config:   {config_path} (not found)")

    # SQLite database (resolve symlinks to show true location)
    db_path = get_sqlite_db_path()
    if db_path:
        if db_path.exists():
            resolved_path = db_path.resolve()
            # Show file size
            size_bytes = db_path.stat().st_size
            if size_bytes < 1024:
                size_str = f"{size_bytes} B"
            elif size_bytes < 1024 * 1024:
                size_str = f"{size_bytes / 1024:.1f} KB"
            else:
                size_str = f"{size_bytes / (1024 * 1024):.1f} MB"
            print(f"   Database: {resolved_path} ({size_str})")
        else:
            print(f"   Database: {db_path} (not created yet)")
    else:
        print("   Database: (SQLite disabled or not configured)")

    # Log file(s) - show based on how service is running (resolve symlinks)
    log_paths = get_active_log_paths()
    for i, (log_path, description) in enumerate(log_paths):
        prefix = "Log:" if i == 0 else "    "
        if log_path.exists():
            resolved_log = log_path.resolve()
            size_bytes = log_path.stat().st_size
            if size_bytes < 1024:
                size_str = f"{size_bytes} B"
            elif size_bytes < 1024 * 1024:
                size_str = f"{size_bytes / 1024:.1f} KB"
            else:
                size_str = f"{size_bytes / (1024 * 1024):.1f} MB"
            # Show description (e.g., stale warning) if present
            desc_str = f" {description}" if description else ""
            print(f"   {prefix:8}  {resolved_log} ({size_str}){desc_str}")
        else:
            print(f"   {prefix:8}  {log_path} ({description})")

    # PID file - only relevant for manual daemon mode (not Homebrew/systemd)
    pid_path = get_pid_file()
    if pid_path.exists():
        # Show if it exists (might be stale from old daemon runs)
        if is_brew_service_running() or is_systemd_service_running():
            print(f"   PID:      {pid_path.resolve()} ⚠️  stale, safe to delete")
        else:
            print(f"   PID:      {pid_path.resolve()}")
    elif not is_brew_service_running() and not is_systemd_service_running():
        # Only show "not created" for manual daemon mode
        print(f"   PID:      {pid_path} (not created)")

    # Local backup status
    print("\n💾 Local sqlite backup:")
    conversation_dir = Path("~/.claude/projects").expanduser()
    backup_complete = False
    if db_path and db_path.exists() and conversation_dir.exists():
        try:
            # Count total .jsonl files on disk
            total_files = len(list(conversation_dir.glob("**/*.jsonl")))

            # Count files tracked in database
            conn = sqlite3.connect(str(db_path))
            cursor = conn.cursor()
            cursor.execute("SELECT COUNT(*) FROM conversation_file_state")
            tracked_files = cursor.fetchone()[0]
            conn.close()

            if total_files == 0:
                print("   No conversation files found")
                backup_complete = True
            elif tracked_files >= total_files:
                print(f"   ✅ Complete ({tracked_files:,} files)")
                backup_complete = True
            else:
                pct = (tracked_files / total_files * 100) if total_files > 0 else 0
                remaining = total_files - tracked_files
                print(
                    f"   🔄 In progress: {tracked_files:,}/{total_files:,} files ({pct:.0f}%)"
                )
                print(f"   Remaining: {remaining:,} files")
        except sqlite3.Error as e:
            print(f"   Error reading database: {e}")
    elif not conversation_dir.exists():
        print("   ⚠️  Conversation directory not found")
        print(f"   Expected: {conversation_dir}")
    else:
        print("   ⏳ Waiting for database to initialize")

    # Remote sync status
    print("\n☁️  Remote sync:")
    api_enabled = False  # Track for use in sync statistics section
    if config_path.exists():
        try:
            with open(config_path, "r") as f:
                config = json.load(f)
            api_config = config.get("api", {})
            api_url = api_config.get("url", "")
            api_key = api_config.get("api_key", "")
            api_enabled = api_config.get("enabled", False)

            if api_key and api_enabled:
                print(f"   ✅ Enabled")
                print(f"   Server: {api_url}")
                print(f"   API Key: {api_key[:8]}...{api_key[-4:]}")
            elif api_key and not api_enabled:
                print(f"   ⚠️  Authenticated but disabled")
                print(f"   Server: {api_url}")
                print("   To enable: set api.enabled=true in config")
            else:
                print("   ❌ Not configured")
                print("   To enable: vibe-check auth login")
        except (json.JSONDecodeError, KeyError):
            print("   ⚠️  Config file invalid")
            print("   To fix: vibe-check auth login")
    else:
        print("   ❌ Not configured")
        print("   To enable: vibe-check auth login")

    # Sync statistics (part of Remote sync section)
    if db_path and db_path.exists():
        try:
            conn = sqlite3.connect(str(db_path))
            cursor = conn.cursor()

            # Check if synced_at column exists
            cursor.execute("PRAGMA table_info(conversation_events)")
            columns = [row[1] for row in cursor.fetchall()]

            if "synced_at" in columns:
                cursor.execute("SELECT COUNT(*) FROM conversation_events")
                total = cursor.fetchone()[0]

                cursor.execute(
                    "SELECT COUNT(*) FROM conversation_events WHERE synced_at IS NOT NULL"
                )
                synced = cursor.fetchone()[0]

                pending = total - synced
                pct = (synced / total * 100) if total > 0 else 0

                print(f"   Events:    {synced:,}/{total:,} synced ({pct:.1f}%)")

                if pending > 0 and api_enabled:
                    # Estimate time to sync at 10 req/sec
                    eta_seconds = pending / 10
                    if eta_seconds < 60:
                        eta_str = f"{eta_seconds:.0f} sec"
                    elif eta_seconds < 3600:
                        eta_str = f"{eta_seconds / 60:.0f} min"
                    else:
                        eta_str = f"{eta_seconds / 3600:.1f} hr"
                    print(f"   ETA:       ~{eta_str} (at 10/sec)")

                # Check if sync worker is actively syncing (recent synced_at timestamps)
                cursor.execute(
                    """
                    SELECT COUNT(*)
                    FROM conversation_events
                    WHERE synced_at > datetime('now', '-2 minutes')
                """
                )
                recent_count = cursor.fetchone()[0]

                if not api_enabled:
                    print(f"   Worker:    ⚪ N/A (sync disabled)")
                elif recent_count > 0 and pending > 0:
                    print(
                        f"   Worker:    🟢 Active ({recent_count} synced in last 2 min)"
                    )
                elif not backup_complete and pending > 0 and pid:
                    print(f"   Worker:    ⏳ Waiting for local backup")
                elif pending > 0 and pid:
                    print(f"   Worker:    🟡 Idle (waiting or backed off)")
                elif pending == 0:
                    print(f"   Worker:    ✅ Complete")
                else:
                    print(f"   Worker:    ⚪ Not running (daemon stopped)")

                # Show last sync time if any synced
                if synced > 0:
                    cursor.execute(
                        "SELECT MAX(synced_at) FROM conversation_events WHERE synced_at IS NOT NULL"
                    )
                    last_sync_time = cursor.fetchone()[0]
                    if last_sync_time:
                        # Calculate relative time
                        try:
                            sync_dt = datetime.strptime(
                                last_sync_time, "%Y-%m-%d %H:%M:%S"
                            )
                            sync_dt = sync_dt.replace(tzinfo=timezone.utc)
                            now_utc = datetime.now(timezone.utc)
                            delta = now_utc - sync_dt
                            total_seconds = delta.total_seconds()

                            if total_seconds < 60:
                                relative = f"{total_seconds} seconds ago"
                            elif total_seconds < 3600:
                                mins = int(total_seconds / 60)
                                relative = f"{mins} min ago"
                            elif total_seconds < 86400:
                                hours = total_seconds / 3600
                                relative = f"{hours:.1f} hours ago"
                            else:
                                days = total_seconds / 86400
                                relative = f"{days:.1f} days ago"

                            print(f"   Last sync: {last_sync_time} UTC ({relative})")
                        except ValueError:
                            print(f"   Last sync: {last_sync_time} UTC")

            else:
                cursor.execute("SELECT COUNT(*) FROM conversation_events")
                total = cursor.fetchone()[0]
                print(
                    f"   Events:    {total:,} (sync tracking not enabled - restart daemon)"
                )

            conn.close()
        except sqlite3.Error as e:
            print(f"   Error reading database: {e}")

    # Claude Integration status (MCP + Skills)
    print("\n🤖 Claude integration:")

    # MCP Plugin status
    mcp_installed = is_mcp_plugin_installed()
    if mcp_installed:
        print("   MCP:    ✅ Installed")
    else:
        print("   MCP:    ❌ Not installed")

    # Skills status
    skills_dir = Path.home() / ".claude" / "skills"

    # Dynamically discover available skills from Homebrew or repo location
    homebrew_skills_dir = Path("/opt/homebrew/share/vibe-check/skills")
    repo_skills_dir = Path(__file__).parent / "skills"

    skills_source_dir = None
    if homebrew_skills_dir.exists():
        skills_source_dir = homebrew_skills_dir
    elif repo_skills_dir.exists():
        skills_source_dir = repo_skills_dir

    # Get list of available skills (vibe-check-* directories with SKILL.md)
    if skills_source_dir:
        skills_to_check = [
            d.name for d in skills_source_dir.glob("vibe-check-*")
            if d.is_dir() and (d / "SKILL.md").exists()
        ]
    else:
        # Fallback: check what's already installed
        skills_to_check = [
            d.name for d in skills_dir.glob("vibe-check-*")
            if d.is_dir() and (d / "SKILL.md").exists()
        ]

    def skill_installed(name):
        """Check if skill is installed (directory format with SKILL.md)"""
        skill_path = skills_dir / name / "SKILL.md"
        return skill_path.exists()

    if skills_dir.exists():
        installed = [s for s in skills_to_check if skill_installed(s)]
        missing = [s for s in skills_to_check if not skill_installed(s)]

        if len(installed) == len(skills_to_check):
            print(f"   Skills: ✅ All {len(skills_to_check)} installed")
        elif installed:
            print(f"   Skills: ⚠️  {len(installed)}/{len(skills_to_check)} installed")
        else:
            print("   Skills: ❌ Not installed")
    else:
        print("   Skills: ❌ Not installed")

    # Show install hint if either is missing
    if not mcp_installed or (
        skills_dir.exists()
        and len([s for s in skills_to_check if skill_installed(s)])
        < len(skills_to_check)
    ):
        print("   To install: run 'vibe-check start'")

    # Git integration status
    print("\n🔗 Git integration:")
    git_status = check_git_hooks_status()

    # Show global hooks status
    if git_status["global_configured"]:
        print(f"   Global ({git_status['global_hooks_dir']}):")
        if git_status["global_hooks"]:
            prepare_status = git_status["global_hooks"].get("prepare-commit-msg", "not_installed")
            post_status = git_status["global_hooks"].get("post-commit", "not_installed")

            if prepare_status == "installed":
                print("      Commit messages: ✅ Enabled")
            else:
                print("      Commit messages: ❌ Not installed")

            if post_status == "installed":
                print("      Git notes:       ✅ Enabled")
            else:
                print("      Git notes:       ❌ Not installed")
        else:
            print("      ⚠️  Hooks directory not found")
    else:
        print("   Global: ❌ Not configured")
        print("      To install: vibe-check git install --global")

    # Show current repo hooks status
    if git_status["cwd_hooks"]:
        cwd = Path.cwd()
        print(f"   Current repo ({cwd.name}):")

        prepare_status = git_status["cwd_hooks"].get("prepare-commit-msg", "not_installed")
        post_status = git_status["cwd_hooks"].get("post-commit", "not_installed")

        def format_status(status):
            if status == "installed":
                return "✅ Enabled"
            elif status == "installed_chained":
                return "✅ Enabled (chained)"
            elif status == "other":
                return "⚠️  Other hook installed"
            else:
                return "❌ Not installed"

        print(f"      Commit messages: {format_status(prepare_status)}")
        print(f"      Git notes:       {format_status(post_status)}")

        # Show install instructions if not all hooks are installed
        if prepare_status not in ("installed", "installed_chained") or \
           post_status not in ("installed", "installed_chained"):
            print("      To install:      vibe-check git install")
    else:
        # Not in a git repo
        print("   Current repo: Not in a git repository")

    # Show management command
    print("\n   Manage hooks:    vibe-check git status")


def cmd_uninstall(args):
    """Uninstall vibe-check data, MCP plugin, hooks, and Claude Code skills."""
    import shutil

    install_dir = Path.home() / ".vibe-check"
    skills_dir = Path.home() / ".claude" / "skills"
    claude_config = Path.home() / ".claude.json"
    claude_settings = Path.home() / ".claude" / "settings.json"
    # Skills to remove (directory names with vibe-check-* prefix)
    skills_to_remove = [
        "vibe-check-stats",
        "vibe-check-search",
        "vibe-check-analyze-tools",
        "vibe-check-recent",
        "vibe-check-view-stats",
        "vibe-check-session-id",
        "vibe-check-share",
    ]

    # Show what will be removed
    print("\n🧜 Vibe Check Uninstaller")
    print("=" * 50)
    print("\nThis will remove:")
    print(f"  - MCP plugin from ~/.claude.json")
    print(f"  - Session tracking hook from ~/.claude/settings.json")
    print(f"  - Claude Code skills from {skills_dir}")
    print(f"  - Data directory: {install_dir}")
    print("    (config, database, logs, PID file)")

    is_brew = is_homebrew_service()
    if is_brew:
        print("\n⚠️  Note: After this, also run:")
        print("      brew uninstall vibe-check")

    print("\nYour server account will NOT be deleted.")
    print()

    # Confirm
    try:
        response = input("Are you sure you want to uninstall? (y/N): ").strip().lower()
        if response not in ["y", "yes"]:
            print("\nUninstall cancelled.")
            return
    except (EOFError, KeyboardInterrupt):
        print("\n\nUninstall cancelled.")
        return

    print()

    # Stop running processes
    pid = is_running()
    if pid:
        print("Stopping vibe-check process...")
        if is_brew and is_homebrew_service_running():
            subprocess.run(
                ["brew", "services", "stop", "vibe-check"], capture_output=True
            )
        else:
            try:
                os.kill(pid, signal.SIGTERM)
                time.sleep(1)
            except ProcessLookupError:
                pass
        print("✓ Process stopped")

    # Remove MCP plugin from ~/.claude.json
    if claude_config.exists():
        try:
            with open(claude_config, "r") as f:
                config = json.load(f)
            if "mcpServers" in config and "vibe-check" in config["mcpServers"]:
                del config["mcpServers"]["vibe-check"]
                with open(claude_config, "w") as f:
                    json.dump(config, f, indent=2)
                print("✓ Removed MCP plugin from ~/.claude.json")
            else:
                print("✓ MCP plugin not found in ~/.claude.json")
        except (json.JSONDecodeError, IOError) as e:
            print(f"⚠️  Could not update ~/.claude.json: {e}")
    else:
        print("✓ No ~/.claude.json found")

    # Remove session tracking hook from ~/.claude/settings.json
    if claude_settings.exists():
        try:
            with open(claude_settings, "r") as f:
                settings = json.load(f)
            hooks = settings.get("hooks", {}).get("UserPromptSubmit", [])
            # Filter out vibe-check hooks
            original_count = len(hooks)
            hooks = [
                h
                for h in hooks
                if not any(
                    "session-tracker" in cmd.get("command", "")
                    or "vibe-check" in cmd.get("command", "")
                    for cmd in h.get("hooks", [])
                )
            ]
            if len(hooks) < original_count:
                if hooks:
                    settings["hooks"]["UserPromptSubmit"] = hooks
                else:
                    # Remove the empty UserPromptSubmit key
                    del settings["hooks"]["UserPromptSubmit"]
                    if not settings["hooks"]:
                        del settings["hooks"]
                with open(claude_settings, "w") as f:
                    json.dump(settings, f, indent=2)
                print("✓ Removed session tracking hook from settings.json")
            else:
                print("✓ Session tracking hook not found in settings.json")
        except (json.JSONDecodeError, IOError, KeyError) as e:
            print(f"⚠️  Could not update settings.json: {e}")
    else:
        print("✓ No ~/.claude/settings.json found")

    # Remove skills
    if skills_dir.exists():
        removed_count = 0
        for skill in skills_to_remove:
            # Remove new directory format (skill-name/SKILL.md)
            skill_dir_path = skills_dir / skill
            if skill_dir_path.is_dir():
                shutil.rmtree(skill_dir_path)
                removed_count += 1
            # Also remove old flat format (skill-name.md) if present
            skill_file_path = skills_dir / f"{skill}.md"
            if skill_file_path.exists():
                skill_file_path.unlink()
                removed_count += 1
        if removed_count > 0:
            print(f"✓ Removed {removed_count} Claude Code skills")
        else:
            print("✓ No Claude Code skills to remove")
    else:
        print("✓ Skills directory not found (nothing to remove)")

    # Remove data directory
    if install_dir.exists():
        shutil.rmtree(install_dir)
        print(f"✓ Removed {install_dir}")
    else:
        print(f"✓ Data directory not found (nothing to remove)")

    print("\n" + "=" * 50)
    print("✅ Uninstall complete!")

    if is_brew:
        print("\n⚠️  To complete uninstall, also run:")
        print("      brew uninstall vibe-check")

    print("\nTo reinstall later:")
    print("  brew install wanderingstan/tap/vibe-check")
    print("  # or: curl -fsSL https://vibecheck.wanderingstan.com/install.sh | bash")
    print()


def cmd_setup(args):
    """Interactive setup wizard for vibe-check installation.

    Orchestrates:
    - Configuration file creation
    - Authentication (optional)
    - Skills installation
    - MCP plugin installation
    - Git hooks setup (optional)
    - Service registration
    - Daemon start

    Args:
        args: Parsed arguments with flags:
            - skip_auth: Skip authentication prompt
            - skip_git: Skip git integration setup
            - non_interactive: Use defaults, no prompts
            - reconfigure: Force reconfiguration
    """
    print("╔═══════════════════════════════════════════════╗")
    print("║   Vibe Check Setup Wizard                     ║")
    print("╚═══════════════════════════════════════════════╝")
    print()

    # Check prerequisites
    print("1️⃣  Checking prerequisites...")

    # Verify Claude Code is installed
    claude_projects = Path.home() / ".claude" / "projects"
    if not claude_projects.exists():
        print("   ❌ Claude Code not found")
        print()
        print("      Vibe Check monitors Claude Code conversations.")
        print("      Please install Claude Code first:")
        print("      https://code.claude.com/docs/en/overview")
        print()
        print("      Run Claude Code at least once, then re-run: vibe-check setup")
        return 1

    print("   ✅ Claude Code detected")

    # Check if already configured
    config_path = get_config_path()
    already_configured = config_path.exists()

    # Check if service is registered
    system = platform.system()
    service_exists = False
    if is_homebrew_service():
        service_exists = True
    elif system == "Darwin":
        service_exists = (Path.home() / "Library/LaunchAgents/com.vibecheck.monitor.plist").exists()
    elif system == "Linux":
        service_exists = is_systemd_service()

    if already_configured and not args.reconfigure:
        print()
        print("✅ Vibe Check is already configured")
        print(f"   Config: {config_path}")
        if service_exists:
            print("   Service: Registered")
        print()
        print("To reconfigure: vibe-check setup --reconfigure")
        print()
        print("Current status:")
        cmd_status(args)
        return 0

    # Configuration
    print()
    print("2️⃣  Configuration...")

    if not config_path.exists():
        print("   Creating default configuration...")
        data_dir = get_data_dir()
        data_dir.mkdir(parents=True, exist_ok=True)

        default_config = {
            "api": {"enabled": False, "url": DEFAULT_API_URL, "api_key": ""},
            "sqlite": {
                "enabled": True,
                "database_path": "~/.vibe-check/vibe_check.db",
                "user_name": os.environ.get("USER", "unknown"),
            },
            "monitor": {"conversation_dir": "~/.claude/projects"},
        }

        with open(config_path, "w") as f:
            json.dump(default_config, f, indent=2)

        print(f"   ✅ Config created: {config_path}")
    else:
        print(f"   ✅ Config exists: {config_path}")

    # Authentication (optional)
    if not args.skip_auth and not args.non_interactive:
        print()
        print("3️⃣  Remote Logging (Optional)...")
        print("   Vibe Check can optionally sync conversations to a remote server")
        print("   for web-based viewing and sharing.")
        print()
        print("   • All conversations are stored locally in SQLite")
        print("   • Remote sync is optional and can be enabled later")
        print()

        response = input("   Enable remote logging? (y/N): ").strip().lower()

        if response in ["y", "yes"]:
            print()
            cmd_auth_login(args)
        else:
            print("   ✅ Skipping - local-only mode")
    elif args.skip_auth:
        print()
        print("3️⃣  Remote Logging...")
        print("   ✅ Skipped (--skip-auth)")
    else:
        print()
        print("3️⃣  Remote Logging...")
        print("   ✅ Skipped (non-interactive mode)")

    # Skills installation
    print()
    print("4️⃣  Claude Code Skills...")

    interactive = not args.non_interactive
    check_claude_skills(interactive=interactive)
    print("   ✅ Skills configured")

    # MCP plugin
    print()
    print("5️⃣  MCP Plugin...")

    check_mcp_plugin(interactive=interactive)
    print("   ✅ MCP plugin configured")

    # Git hooks (optional)
    if not args.skip_git and not args.non_interactive:
        print()
        print("6️⃣  Git Integration (Optional)...")
        print("   Vibe Check can enhance git with:")
        print("   • Claude session links in commit messages")
        print("   • Full conversation transcripts as git notes")
        print()

        response = input("   Install git integration? (y/N): ").strip().lower()

        if response in ["y", "yes"]:
            print()
            check_git_hooks(interactive=True)
        else:
            print("   ✅ Skipping - can install later with: vibe-check git install")
    elif args.skip_git:
        print()
        print("6️⃣  Git Integration...")
        print("   ✅ Skipped (--skip-git)")
    else:
        print()
        print("6️⃣  Git Integration...")
        print("   ✅ Skipped (non-interactive mode)")

    # Service registration
    print()
    print("7️⃣  Service Registration...")

    service_ok = register_service()
    service_was_registered = False

    # Check if LaunchAgent or systemd service was just created
    system = platform.system()
    if service_ok:
        if system == "Darwin":
            plist_path = Path.home() / "Library/LaunchAgents/com.vibecheck.monitor.plist"
            service_was_registered = plist_path.exists() and not is_homebrew_service()
        elif system == "Linux":
            service_path = Path.home() / ".config/systemd/user/vibe-check.service"
            service_was_registered = service_path.exists()

    if not service_ok:
        print("   ⚠️  Service registration had issues")
        print("      You can start manually with: vibe-check start")

    # Start daemon (skip if LaunchAgent/systemd service was just registered, as it auto-starts)
    print()
    print("8️⃣  Starting daemon...")

    if service_was_registered:
        print("   ⏳ Waiting for system service to start...")
        # Give the service time to start (LaunchAgent can be slow on first boot)
        max_wait = 10
        for i in range(max_wait):
            time.sleep(1)
            pid = is_running()
            if pid:
                print(f"   ✅ Service started (PID: {pid})")
                break
        else:
            # Service didn't start - fall back to manual start via subprocess
            print("   ⚠️  Service didn't auto-start, starting manually...")
            try:
                # Use subprocess to avoid daemonize() forking issues when called from setup
                script_dir = Path(__file__).parent
                wrapper = script_dir / "vibe-check"
                if not wrapper.exists():
                    wrapper = Path.home() / ".vibe-check/vibe-check"

                if wrapper.exists():
                    subprocess.Popen([str(wrapper), "start"],
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL,
                                   start_new_session=True)
                    time.sleep(2)  # Give daemon time to start
                    pid = is_running()
                    if pid:
                        print(f"   ✅ Daemon started (PID: {pid})")
                    else:
                        print("   ⚠️  Daemon is starting in background...")
                else:
                    print("   ⚠️  Cannot find vibe-check wrapper script")
                    print("      Try manually: vibe-check start")
            except Exception as e:
                logger.error(f"Failed to start daemon: {e}")
                print(f"   ⚠️  Failed to start daemon: {e}")
                print("      Try manually: vibe-check start")
    else:
        pid = is_running()
        if pid:
            print(f"   ✅ Already running (PID: {pid})")
        else:
            # Use subprocess to avoid daemonize() forking issues when called from setup
            try:
                script_dir = Path(__file__).parent
                wrapper = script_dir / "vibe-check"
                if not wrapper.exists():
                    wrapper = Path.home() / ".vibe-check/vibe-check"

                if wrapper.exists():
                    subprocess.Popen([str(wrapper), "start"],
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL,
                                   start_new_session=True)
                    time.sleep(2)  # Give daemon time to start
                    pid = is_running()
                    if pid:
                        print(f"   ✅ Daemon started (PID: {pid})")
                    else:
                        print("   ⚠️  Daemon is starting in background...")
                else:
                    print("   ⚠️  Cannot find vibe-check wrapper script")
                    print("      Try manually: vibe-check start")
            except Exception as e:
                logger.error(f"Failed to start daemon: {e}")
                print(f"   ⚠️  Failed to start daemon: {e}")
                print("      Try manually: vibe-check start")

    # Success summary
    print()
    print("╔═══════════════════════════════════════════════╗")
    print("║   Setup Complete!                             ║")
    print("╚═══════════════════════════════════════════════╝")
    print()

    # Give daemon time to start
    time.sleep(2)

    # Show status
    cmd_status(args)

    print()
    print("Next steps:")
    print("  • Use Claude Code as normal - conversations are monitored automatically")
    print("  • Ask Claude: 'claude stats' to see your usage")
    print("  • Run 'vibe-check status' anytime to check the daemon")
    print()

    return 0


def cmd_logs(args):
    """View vibe-check process logs."""
    log_paths = get_active_log_paths()

    # Find first existing log file
    log_file = None
    for path, description in log_paths:
        if path.exists() and path.stat().st_size > 0:
            log_file = path
            break

    if not log_file:
        # Show what we looked for
        paths_checked = [str(p) for p, _ in log_paths]
        print(f"⚠️  No log files found. Checked:")
        for p in paths_checked:
            print(f"   - {p}")
        return

    # Show last 50 lines
    lines = args.lines if hasattr(args, "lines") and args.lines else 50

    try:
        with open(log_file, "r") as f:
            all_lines = f.readlines()
            recent_lines = all_lines[-lines:]
            print(f"🧜 Last {len(recent_lines)} lines of {log_file}:\n")
            print("".join(recent_lines))
    except Exception as e:
        print(f"Error reading log file: {e}")


def get_doctor_info():
    """Get diagnostic information for vibe-check troubleshooting.

    Returns:
        dict with keys:
            - status_text: Full status output
            - config_path: Path to config file
            - db_path: Path to database file (or None)
            - repo_dir: Current working directory
    """
    import io
    import sys

    # Get paths
    config_path = get_config_path()
    db_path = get_sqlite_db_path()
    repo_dir = Path.cwd()

    # Capture status output
    old_stdout = sys.stdout
    sys.stdout = captured_output = io.StringIO()

    try:
        # Run status command
        status_args = type('Args', (), {'command': 'status'})()
        cmd_status(status_args)
        status_text = captured_output.getvalue()
    finally:
        sys.stdout = old_stdout

    return {
        "status_text": status_text,
        "config_path": str(config_path),
        "db_path": str(db_path) if db_path else None,
        "repo_dir": str(repo_dir),
    }


def cmd_doctor(args):
    """Launch Claude Code with troubleshooting context for vibe-check."""
    print("🩺 Launching Claude Code for vibe-check troubleshooting...")
    print("   This will start an interactive Claude session with context about:")
    print("   • Current vibe-check status")
    print("   • Configuration file location")
    print("   • Codebase documentation (CLAUDE.md)")
    print()

    # Get diagnostic info
    info = get_doctor_info()
    config_path = info["config_path"]
    status_text = info["status_text"]
    repo_dir = Path(info["repo_dir"])

    # Construct prompt for Claude
    prompt = f"""I need help troubleshooting and configuring vibe-check.

Please help me understand the current state and fix any issues.

**Current Status:**
```
{status_text}
```

**Config Location:** {config_path}

**Instructions:**
1. First, review the CLAUDE.md file in this repository to understand the codebase structure
2. Check the current status output above for any issues
3. If I haven't already shared it, you can read the config file at: {config_path}
4. Help me diagnose and fix any problems you see
5. If everything looks good, help me understand how vibe-check is configured and running

Please be proactive about reading relevant files and suggesting fixes."""

    # Launch Claude Code with the prompt
    try:
        # Check if we're in the vibe-check repo
        if not (repo_dir / "vibe-check.py").exists():
            print(f"⚠️  Warning: Not in vibe-check repository directory")
            print(f"   Current directory: {repo_dir}")
            print(f"\n   Launching Claude Code anyway, but context may be limited.\n")

        # Launch Claude Code with prompt via stdin
        result = subprocess.run(
            ["claude"],
            input=prompt,
            text=True,
            cwd=str(repo_dir),
            check=False
        )

        if result.returncode != 0:
            print(f"\n❌ Claude Code exited with error code {result.returncode}")

    except FileNotFoundError:
        print("❌ Claude Code CLI not found.")
        print("   Please install Claude Code first:")
        print("   https://github.com/anthropics/claude-code")
    except Exception as e:
        print(f"❌ Error launching Claude Code: {e}")


def cmd_git_install(args):
    """Install git hooks to current repo or globally."""
    install_script = Path(__file__).parent / "scripts" / "install-git-hook.sh"

    if not install_script.exists():
        print("❌ Install script not found")
        print(f"   Expected: {install_script}")
        return

    # Build command arguments
    cmd_args = [str(install_script)]

    if args.global_install:
        cmd_args.append("--global")

    if hasattr(args, 'no_notes') and args.no_notes:
        cmd_args.append("--no-notes")

    if hasattr(args, 'path') and args.path:
        cmd_args.append(args.path)

    # Run install script
    result = subprocess.run(cmd_args)
    sys.exit(result.returncode)


def cmd_git_uninstall(args):
    """Uninstall git hooks from current repo or globally."""
    if args.global_install:
        # Remove global hooks
        global_hooks_dir = Path.home() / ".vibe-check" / "git-hooks"
        hooks_path = subprocess.run(
            ["git", "config", "--global", "--get", "core.hooksPath"],
            capture_output=True,
            text=True
        ).stdout.strip()

        if hooks_path == str(global_hooks_dir):
            print("🗑️  Removing global git hooks...")
            # Unset global hooks path
            subprocess.run(["git", "config", "--global", "--unset", "core.hooksPath"])
            print("✅ Removed global hooks configuration")

            # Optionally remove the hooks directory
            if global_hooks_dir.exists():
                print(f"\n📁 Global hooks directory still exists: {global_hooks_dir}")
                print("   You can manually delete it if desired")
        else:
            print("⚠️  Global hooks path is not set to vibe-check")
            if hooks_path:
                print(f"   Current path: {hooks_path}")
    else:
        # Remove from current repo
        cwd = Path.cwd()
        hooks_dir = cwd / ".git" / "hooks"

        if not hooks_dir.exists():
            print("❌ Not a git repository")
            return

        print("🗑️  Removing git hooks from current repository...")

        removed_any = False
        for hook_name in ["prepare-commit-msg", "post-commit"]:
            hook_path = hooks_dir / hook_name
            if hook_path.exists() and hook_path.is_symlink():
                target = hook_path.resolve()
                if "vibe-check" in str(target):
                    hook_path.unlink()
                    print(f"✅ Removed {hook_name}")
                    removed_any = True

                    # Restore .local version if it exists
                    local_hook = hooks_dir / f"{hook_name}.local"
                    if local_hook.exists():
                        local_hook.rename(hook_path)
                        print(f"   Restored {hook_name}.local as {hook_name}")

        if not removed_any:
            print("ℹ️  No vibe-check hooks found in current repository")


def cmd_git_status(args):
    """Show git hooks status (global and current repo)."""
    print("\033[1m🔗 Git Integration Status\033[0m")
    print("")

    # Check global configuration
    print("🌍 Global configuration:")
    hooks_path = subprocess.run(
        ["git", "config", "--global", "--get", "core.hooksPath"],
        capture_output=True,
        text=True
    ).stdout.strip()

    if hooks_path:
        global_hooks_dir = Path(hooks_path).expanduser()
        print(f"   Hooks path: {global_hooks_dir}")

        if global_hooks_dir.exists():
            # Check which hooks are installed
            prepare_hook = global_hooks_dir / "prepare-commit-msg"
            post_hook = global_hooks_dir / "post-commit"

            prepare_installed = prepare_hook.exists() and (
                prepare_hook.is_symlink() and "vibe-check" in str(prepare_hook.resolve())
                or not prepare_hook.is_symlink()
            )
            post_installed = post_hook.exists() and (
                post_hook.is_symlink() and "vibe-check" in str(post_hook.resolve())
                or not post_hook.is_symlink()
            )

            if prepare_installed:
                print("   Commit messages: ✅ Enabled")
            else:
                print("   Commit messages: ❌ Not installed")

            if post_installed:
                print("   Git notes:       ✅ Enabled")
            else:
                print("   Git notes:       ❌ Not installed")
        else:
            print("   ⚠️  Hooks directory does not exist")
    else:
        print("   ❌ Not configured")
        print("   To install: vibe-check git install --global")

    # Check current repo
    print("\n📁 Current repository:")
    cwd = Path.cwd()
    hooks_dir = cwd / ".git" / "hooks"

    if hooks_dir.exists():
        print(f"   Repository: {cwd.name}")

        # Check hooks
        prepare_hook = hooks_dir / "prepare-commit-msg"
        post_hook = hooks_dir / "post-commit"

        def check_hook(hook_path):
            if not hook_path.exists():
                return "not_installed"
            if hook_path.is_symlink():
                target = hook_path.resolve()
                if "vibe-check" in str(target):
                    # Check for chained hook
                    local_hook = hook_path.with_suffix('.local')
                    if local_hook.exists():
                        return "installed_chained"
                    return "installed"
                else:
                    return "other"
            else:
                return "other"

        prepare_status = check_hook(prepare_hook)
        post_status = check_hook(post_hook)

        if prepare_status == "installed":
            print("   Commit messages: ✅ Enabled")
        elif prepare_status == "installed_chained":
            print("   Commit messages: ✅ Enabled (chained)")
        elif prepare_status == "other":
            print("   Commit messages: ⚠️  Other hook installed")
        else:
            print("   Commit messages: ❌ Not installed")

        if post_status == "installed":
            print("   Git notes:       ✅ Enabled")
        elif post_status == "installed_chained":
            print("   Git notes:       ✅ Enabled (chained)")
        elif post_status == "other":
            print("   Git notes:       ⚠️  Other hook installed")
        else:
            print("   Git notes:       ❌ Not installed")

        # Show install command if not all hooks are installed
        if prepare_status != "installed" and prepare_status != "installed_chained" or \
           post_status != "installed" and post_status != "installed_chained":
            print("   To install:      vibe-check git install")
    else:
        print("   Not a git repository")
        print("   Run from a git repo to see local status")


def cmd_auth_login(args):
    """Authenticate with the vibe-check server using device flow."""
    # Load config to get API URL
    config_path = get_config_path()

    if not config_path.exists():
        # Use default production URL
        api_url = DEFAULT_API_URL
        print(f"Using default server: {api_url}")
        # Create basic config
        config = {
            "api": {"enabled": True, "url": api_url, "api_key": ""},
            "monitor": {"conversation_dir": "~/.claude/projects"},
            "sqlite": {"enabled": True, "database_path": "~/.vibe-check/vibe_check.db"},
        }
    else:
        with open(config_path, "r") as f:
            config = json.load(f)
        api_url = config.get("api", {}).get("url", "") or DEFAULT_API_URL

        # Ensure sqlite section exists (for configs created before sqlite support)
        if "sqlite" not in config:
            config["sqlite"] = {
                "enabled": True,
                "database_path": "~/.vibe-check/vibe_check.db",
            }

    # Remove trailing /api if present for the auth endpoint base
    auth_base = api_url.rstrip("/")
    if auth_base.endswith("/api"):
        auth_base = auth_base[:-4]

    print(f"\n🔐 Starting authentication with {auth_base}...")

    try:
        # Start device flow
        # Note: Custom User-Agent required - mod_security blocks python-requests default UA
        response = requests.post(
            f"{auth_base}/api/cli/auth/start",
            json={},
            headers={"User-Agent": "vibe-check-cli/1.0"},
            timeout=10,
        )
        response.raise_for_status()
        data = response.json()

        device_code = data["device_code"]
        user_code = data["user_code"]
        verification_url = data["verification_url_complete"]
        expires_in = data.get("expires_in", 600)
        interval = data.get("interval", 5)

        print(f"\n" + "=" * 50)
        print(f"  Your code: {user_code}")
        print(f"=" * 50)
        print(f"\nOpening browser to: {verification_url}")
        print(f"(Code expires in {expires_in // 60} minutes)")

        # Try to open browser
        try:
            webbrowser.open(verification_url)
        except Exception:
            print(f"\n⚠️  Could not open browser automatically.")
            print(f"   Please visit: {verification_url}")

        print("\nWaiting for authorization", end="", flush=True)

        # Poll for approval
        start_time = time.time()
        while time.time() - start_time < expires_in:
            time.sleep(interval)
            print(".", end="", flush=True)

            try:
                poll_response = requests.post(
                    f"{auth_base}/api/cli/auth/poll",
                    json={"device_code": device_code},
                    headers={"User-Agent": "vibe-check-cli/1.0"},
                    timeout=10,
                )

                if poll_response.status_code == 200:
                    poll_data = poll_response.json()
                    if poll_data.get("status") == "approved":
                        api_key = poll_data.get("api_key")
                        print("\n\n✅ Authorization successful!")

                        # Save to config
                        config["api"]["url"] = api_url
                        config["api"]["api_key"] = api_key
                        config["api"]["enabled"] = True

                        config_path.parent.mkdir(parents=True, exist_ok=True)
                        with open(config_path, "w") as f:
                            json.dump(config, f, indent=2)

                        print(f"   API key saved to {config_path}")

                        # Restart daemon if running so it picks up the new config
                        pid = is_running()
                        if pid:
                            print("\n🔄 Restarting daemon to enable sync...")
                            cmd_restart(args)

                        return

                elif poll_response.status_code == 202:
                    # Still pending, continue polling
                    continue
                else:
                    error_data = poll_response.json()
                    error = error_data.get("error", "Unknown error")
                    if error in ["expired_token", "token_already_used"]:
                        print(f"\n\n❌ {error.replace('_', ' ').title()}")
                        return

            except requests.RequestException as e:
                # Network error during poll, continue trying
                continue

        print("\n\n❌ Authorization timed out. Please try again.")

    except requests.RequestException as e:
        print(f"\n❌ Error connecting to server: {e}")
        sys.exit(1)


def cmd_auth_status(args):
    """Show current authentication status."""
    config_path = get_config_path()

    if not config_path.exists():
        print("⚠️  Not configured. Run 'vibe-check auth login' to authenticate.")
        return

    with open(config_path, "r") as f:
        config = json.load(f)

    api_config = config.get("api", {})
    api_url = api_config.get("url", "")
    api_key = api_config.get("api_key", "")
    enabled = api_config.get("enabled", False)

    if api_key:
        print("✅ Authenticated")
        print(f"   Server: {api_url}")
        print(f"   API Key: {api_key[:8]}...{api_key[-4:]}")
        print(f"   Remote sync: {'enabled' if enabled else 'disabled'}")
    else:
        print("⚠️  Not authenticated")
        if api_url:
            print(f"   Server: {api_url}")
        print("\n   Run 'vibe-check auth login' to authenticate.")


def cmd_auth_logout(args):
    """Remove stored API key."""
    config_path = get_config_path()

    if not config_path.exists():
        print("⚠️  No config file found. Nothing to log out from.")
        return

    with open(config_path, "r") as f:
        config = json.load(f)

    if not config.get("api", {}).get("api_key"):
        print("⚠️  Not currently authenticated.")
        return

    # Clear API key
    config["api"]["api_key"] = ""

    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)

    print("✅ Logged out. API key removed from config.")


def run_monitor(args):
    """Run the vibe-check process (extracted from main for daemon support)."""
    # Set up logging for console if not already configured (foreground mode)
    if not logger.handlers:
        setup_logging()

    # Ensure data directory exists
    data_dir = get_data_dir()
    data_dir.mkdir(parents=True, exist_ok=True)

    # Load configuration
    config_path = get_config_path()

    if not config_path.exists():
        # Create default config on first run
        logger.info(f"Creating default configuration at: {config_path}")
        default_config = {
            "api": {"enabled": False, "url": "", "api_key": ""},
            "sqlite": {
                "enabled": True,
                "database_path": "~/.vibe-check/vibe_check.db",
                "user_name": os.environ.get("USER", "unknown"),
            },
            "monitor": {"conversation_dir": "~/.claude/projects"},
        }
        with open(config_path, "w") as f:
            json.dump(default_config, f, indent=2)
        config = default_config
    else:
        with open(config_path, "r") as f:
            config = json.load(f)

    # Expand paths
    conversation_dir = Path(config["monitor"]["conversation_dir"]).expanduser()

    if not conversation_dir.exists():
        logger.error(f"Conversation directory not found: {conversation_dir}")
        sys.exit(1)

    logger.info(f"Monitoring directory: {conversation_dir}")

    # Check for Claude Code skills (unless skipped)
    if not args.skip_skills_check:
        check_claude_skills()

    # Auto-update global git hooks if configured
    update_global_git_hooks_if_needed()

    # Check for git hooks (unless skipped)
    if not args.skip_skills_check:
        check_git_hooks()

    # Debug filter
    debug_filter = config["monitor"].get("debug_filter_project")
    if debug_filter:
        logger.debug(f"Only processing project: {debug_filter}")

    # Initialize state manager (uses SQLite database)
    db_path = get_data_dir() / "vibe_check.db"
    state_manager = StateManager(db_path)

    # Handle skip-backlog flag
    if args.skip_backlog:
        state_manager.skip_to_end(conversation_dir, debug_filter)

    # Initialize SQLite manager
    sqlite_manager = None
    if "sqlite" in config:
        sqlite_manager = SQLiteManager(config["sqlite"])

    # Initialize monitor
    event_handler = ConversationMonitor(
        config["api"], state_manager, conversation_dir, sqlite_manager, debug_filter
    )

    # Process existing files first (unless we just skipped backlog)
    if not args.skip_backlog:
        event_handler.process_existing_files(conversation_dir)

    # Start background sync worker (syncs pending events to API)
    event_handler.start_sync_worker()

    # Start watching for changes
    observer = Observer()
    observer.schedule(event_handler, str(conversation_dir), recursive=True)
    observer.start()

    logger.info("Monitoring for changes... (Press Ctrl+C to stop)")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        logger.info("Stopping vibe-check process...")
        event_handler.stop_sync_worker()
        observer.stop()

    observer.join()
    logger.info("vibe-check process Monitor stopped")


def main():
    """Main entry point with subcommands."""
    parser = argparse.ArgumentParser(
        description="Vibe Check: Claude Code Conversation tooling",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Commands:
  setup         Run setup wizard (auth, skills, git, service)
  start         Start the vibe-check process in background
  stop          Stop the background process
  restart       Restart vibe-check process
  status        Check if vibe-check process is running
  logs          View vibe-check logs
  doctor        Launch Claude Code to troubleshoot vibe-check
  uninstall     Remove vibe-check data and Claude Code skills
  auth login    Authenticate with the vibe-check server
  auth status   Show current authentication status
  auth logout   Remove stored API key
  git install   Install git hooks (global or current repo)
  git uninstall Remove git hooks
  git status    Show git hooks status
  (no command)  Show status if running, or prompt to start

Examples:
  vibe-check setup              # Run interactive setup wizard
  vibe-check setup --skip-auth  # Setup without authentication
  vibe-check auth login         # Authenticate with the server
  vibe-check start              # Start in background
  vibe-check stop               # Stop background monitor
  vibe-check status             # Check status
  vibe-check logs               # View logs
  vibe-check doctor             # Get AI help troubleshooting
  vibe-check --skip-backlog     # Run foreground, skip existing conversations
        """,
    )

    # Version flag
    parser.add_argument(
        "--version",
        "-V",
        action="version",
        version=f"vibe-check {VERSION}",
    )

    # Global arguments (work with any command)
    parser.add_argument(
        "--skip-backlog",
        action="store_true",
        help="Skip existing conversation history and start monitoring from current position",
    )
    parser.add_argument(
        "--skip-skills-check",
        action="store_true",
        help="Skip checking for Claude Code skills installation",
    )
    parser.add_argument(
        "--run",
        action="store_true",
        help="Run monitor directly (skip interactive prompt, for services)",
    )

    # Create subparsers
    subparsers = parser.add_subparsers(dest="command", help="Command to execute")

    # Start command
    parser_start = subparsers.add_parser(
        "start", help="Start vibe-check process in background"
    )
    parser_start.add_argument(
        "--foreground",
        "-f",
        action="store_true",
        help="Run in foreground (for systemd/launchd)",
    )
    parser_start.set_defaults(func=cmd_start)

    # Stop command
    parser_stop = subparsers.add_parser(
        "stop", help="Stop background vibe-check process"
    )
    parser_stop.set_defaults(func=cmd_stop)

    # Restart command
    parser_restart = subparsers.add_parser(
        "restart", help="Restart background vibe-check process"
    )
    parser_restart.set_defaults(func=cmd_restart)

    # Status command
    parser_status = subparsers.add_parser(
        "status", help="Check vibe-check process status"
    )
    parser_status.set_defaults(func=cmd_status)

    # Logs command
    parser_logs = subparsers.add_parser("logs", help="View vibe-check logs")
    parser_logs.add_argument(
        "-n",
        "--lines",
        type=int,
        default=50,
        help="Number of lines to show (default: 50)",
    )
    parser_logs.set_defaults(func=cmd_logs)

    # Doctor command
    parser_doctor = subparsers.add_parser(
        "doctor", help="Launch Claude Code to troubleshoot vibe-check"
    )
    parser_doctor.set_defaults(func=cmd_doctor)

    # Uninstall command
    parser_uninstall = subparsers.add_parser(
        "uninstall", help="Remove vibe-check data and Claude Code skills"
    )
    parser_uninstall.set_defaults(func=cmd_uninstall)

    # Setup command
    parser_setup = subparsers.add_parser(
        "setup",
        help="Run interactive setup wizard (auth, skills, git, service)"
    )
    parser_setup.add_argument(
        "--skip-auth",
        action="store_true",
        help="Skip authentication prompt (local-only mode)"
    )
    parser_setup.add_argument(
        "--skip-git",
        action="store_true",
        help="Skip git integration setup"
    )
    parser_setup.add_argument(
        "--non-interactive",
        action="store_true",
        help="Use defaults without prompts (for automation)"
    )
    parser_setup.add_argument(
        "--reconfigure",
        action="store_true",
        help="Force reconfiguration even if already set up"
    )
    parser_setup.set_defaults(func=cmd_setup)

    # Git command with subcommands
    parser_git = subparsers.add_parser("git", help="Git integration commands")
    git_subparsers = parser_git.add_subparsers(
        dest="git_command", help="Git command"
    )

    # git install
    parser_git_install = git_subparsers.add_parser(
        "install", help="Install git hooks to current repo or globally"
    )
    parser_git_install.add_argument(
        "--global", dest="global_install", action="store_true",
        help="Install hooks globally (all repos)"
    )
    parser_git_install.add_argument(
        "--no-notes", dest="no_notes", action="store_true",
        help="Skip git notes hook (only install commit messages)"
    )
    parser_git_install.add_argument(
        "path", nargs="?", help="Repository path (default: current directory)"
    )
    parser_git_install.set_defaults(func=cmd_git_install)

    # git uninstall
    parser_git_uninstall = git_subparsers.add_parser(
        "uninstall", help="Remove git hooks from current repo or globally"
    )
    parser_git_uninstall.add_argument(
        "--global", dest="global_install", action="store_true",
        help="Remove global hooks"
    )
    parser_git_uninstall.set_defaults(func=cmd_git_uninstall)

    # git status
    parser_git_status = git_subparsers.add_parser(
        "status", help="Show git hooks status (global and current repo)"
    )
    parser_git_status.set_defaults(func=cmd_git_status)

    # Default for 'git' with no subcommand
    parser_git.set_defaults(func=cmd_git_status)

    # Auth command with subcommands
    parser_auth = subparsers.add_parser("auth", help="Authentication commands")
    auth_subparsers = parser_auth.add_subparsers(
        dest="auth_command", help="Auth command"
    )

    # auth login
    parser_auth_login = auth_subparsers.add_parser(
        "login", help="Authenticate with the vibe-check server"
    )
    parser_auth_login.set_defaults(func=cmd_auth_login)

    # auth status
    parser_auth_status = auth_subparsers.add_parser(
        "status", help="Show current authentication status"
    )
    parser_auth_status.set_defaults(func=cmd_auth_status)

    # auth logout
    parser_auth_logout = auth_subparsers.add_parser(
        "logout", help="Remove stored API key"
    )
    parser_auth_logout.set_defaults(func=cmd_auth_logout)

    # Default for 'auth' with no subcommand
    parser_auth.set_defaults(func=cmd_auth_status)

    # Parse arguments
    args = parser.parse_args()

    # If a subcommand was specified, run it
    if hasattr(args, "func"):
        args.func(args)
    elif args.run:
        # --run flag: run monitor directly without prompting (for services)
        run_monitor(args)
    else:
        # No subcommand - check if already running
        pid = is_running()
        if pid:
            # Already running, show status
            cmd_status(args)
        else:
            # Not running, prompt user for how to run
            print("🧜 Vibe Check is not running.")
            print("\nHow would you like to run it?")
            print("  [f] Foreground (see output, Ctrl+C to stop)")
            print("  [b] Background (runs as daemon)")
            print("  [q] Quit")
            print("\nChoice [f/b/q]: ", end="", flush=True)

            try:
                choice = input().strip().lower()
                if choice in ["f", "foreground"]:
                    run_monitor(args)
                elif choice in ["b", "background"]:
                    cmd_start(args)
                elif choice in ["q", "quit", ""]:
                    print("Exiting.")
                else:
                    print(f"Unknown choice: {choice}")
                    sys.exit(1)
            except (EOFError, KeyboardInterrupt):
                print("\nExiting.")
                sys.exit(0)


if __name__ == "__main__":
    main()
