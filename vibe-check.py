#!/usr/bin/env python3
"""
vibe-check: Claude Code Conversation Monitor

Monitors .jsonl files in the Claude Code conversations directory and
sends new events to the Vibe Check API server.
"""

import argparse
import copy
import json
import logging
import os
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

# Create module-level logger
logger = logging.getLogger("vibe-check")

# Version
VERSION = "1.1.0"

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
        # File handler for daemon mode
        log_file.parent.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(log_file)
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
    """Manages state tracking for file processing using SQLite."""

    def __init__(self, db_path: Path):
        self.db_path = db_path
        self.connection = None
        self.cursor = None
        self._connect()
        self._migrate_from_json()

    def _connect(self):
        """Establish SQLite connection."""
        self.connection = sqlite3.connect(str(self.db_path), check_same_thread=False)
        self.cursor = self.connection.cursor()
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
        logger.info(f"StateManager connected: {count} files tracked")

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
        self.cursor.execute(
            "SELECT last_line FROM conversation_file_state WHERE file_name = ?",
            (filename,),
        )
        row = self.cursor.fetchone()
        return row[0] if row else 0

    def set_last_line(self, filename: str, line_number: int):
        """Set the last processed line number for a file."""
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
        self.cursor.execute("SELECT COUNT(*) FROM conversation_file_state")
        return self.cursor.fetchone()[0]

    def close(self):
        """Close the database connection."""
        if self.connection:
            self.connection.close()


class SQLiteManager:
    """Manages SQLite database connections and operations."""

    def __init__(self, config: dict):
        """Initialize SQLite manager with configuration."""
        self.config = config
        self.enabled = config.get("enabled", True)
        self.user_name = config.get("user_name", "unknown")
        self.connection = None
        self.cursor = None
        self.db_path = None

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
            logger.info(f"Connected to SQLite database: {self.db_path}")
        except Exception as e:
            logger.error(f"Error initializing SQLite: {e}")
            logger.warning(
                "SQLite recording will be disabled. Events will still be sent to API."
            )
            self.enabled = False

    def connect(self):
        """Establish SQLite connection."""
        self.connection = sqlite3.connect(str(self.db_path), check_same_thread=False)
        self.cursor = self.connection.cursor()

    def create_schema(self):
        """Create database schema if it doesn't exist."""
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

        # Create view for events with messages (filters out null/empty messages)
        self.cursor.execute(
            """
            CREATE VIEW IF NOT EXISTS conversation_events_with_messages AS
            SELECT
                event_timestamp,
                event_type,
                event_message,
                event_uuid,
                event_session_id,
                event_git_branch,
                git_commit_hash,
                file_name,
                line_number,
                id
            FROM conversation_events
            WHERE event_message IS NOT NULL
              AND event_message != 'null'
              AND event_message != ''
        """
        )

        self.connection.commit()

    def _migrate_schema(self):
        """Run schema migrations for existing databases."""
        # Check if synced_at column exists
        self.cursor.execute("PRAGMA table_info(conversation_events)")
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
        """Process new lines in a JSONL file."""
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
                return

            logger.info(f"Processing {len(new_lines)} new line(s) from {filename}")

            # Track counts
            stored_count = 0
            skipped_count = 0

            for idx, line in enumerate(new_lines):
                line_number = last_line + idx + 1
                line = line.strip()

                if not line:
                    skipped_count += 1
                    continue

                try:
                    # Parse JSON
                    event_data = json.loads(line)

                    # Store in local database (API sync handled by background worker)
                    if self.insert_event(filename, line_number, event_data):
                        stored_count += 1

                    # Update state
                    self.state_manager.set_last_line(filename, line_number)

                except json.JSONDecodeError as e:
                    logger.warning(f"Invalid JSON at {filename}:{line_number}: {e}")
                    # Still update state to skip this line
                    self.state_manager.set_last_line(filename, line_number)
                    skipped_count += 1

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


def check_mcp_plugin():
    """Check if MCP plugin is installed and auto-install if not.

    The MCP plugin provides structured tool interfaces for Claude Code,
    enabling commands like /stats, /search, /share etc.
    """
    if is_mcp_plugin_installed():
        return  # Already installed

    # Find the plugin installer
    # First check Homebrew location
    homebrew_installer = Path("/opt/homebrew/share/vibe-check/scripts/install-plugin.sh")
    if homebrew_installer.exists():
        installer_path = homebrew_installer
        script_dir = homebrew_installer.parent.parent
    else:
        # Check if we're in the vibe-check directory
        script_dir = Path(__file__).parent
        installer_path = script_dir / "scripts" / "install-plugin.sh"

    if not installer_path.exists():
        # Installer not available
        logger.debug(f"Plugin installer not found at {installer_path}")
        return

    # Auto-install the MCP plugin
    print("\n" + "=" * 70)
    print("🔌 Installing Claude Code MCP Plugin...")
    print("=" * 70)
    print("\nThis enables structured commands like /stats, /search, /share")
    print("and natural language queries about your conversation history.\n")

    try:
        result = subprocess.run(
            ["bash", str(installer_path)],
            cwd=str(script_dir),
            capture_output=False,
        )
        if result.returncode == 0:
            print("\n✅ MCP plugin installed successfully!")
            print("   Restart Claude Code to use the new commands.")
        else:
            print("\n⚠️  Plugin installation had issues.")
            print(f"   You can install manually: {installer_path}")
    except Exception as e:
        logger.warning(f"Could not install MCP plugin: {e}")
        print(f"\n⚠️  Could not install MCP plugin: {e}")
        print(f"   You can install manually: {installer_path}")

    print("=" * 70)
    print()


def check_claude_skills():
    """Check if Claude Code skills are installed and prompt to install if not."""
    skills_dir = Path.home() / ".claude" / "skills"
    # New directory-based skill names (vibe-check-* prefix)
    skills_to_check = [
        "vibe-check-stats",
        "vibe-check-search",
        "vibe-check-analyze-tools",
        "vibe-check-recent",
        "vibe-check-view-stats",
    ]

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
        # Copy skill directories (new structure: vibe-check-*/SKILL.md)
        for skill_src_dir in homebrew_skills_dir.glob("vibe-check-*"):
            if skill_src_dir.is_dir():
                dest = skills_dir / skill_src_dir.name
                if not dest.exists():
                    try:
                        shutil.copytree(skill_src_dir, dest)
                        installed_count += 1
                    except Exception as e:
                        logger.warning(f"Could not install skill {skill_src_dir.name}: {e}")
        if installed_count > 0:
            logger.info(
                f"Installed {installed_count} Claude Code skills to {skills_dir}"
            )
        return

    # Check if we're in the vibe-check directory with the installer
    script_dir = Path(__file__).parent
    installer_path = script_dir / "scripts" / "install-plugin.sh"

    if not installer_path.exists():
        # Installer not available (maybe installed via package manager)
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
        error_log = brew_log_dir / "vibe-check.error.log"
        stdout_log = brew_log_dir / "vibe-check.log"

        if error_log.exists():
            logs.append((error_log, "brew service log"))
        if stdout_log.exists() and stdout_log.stat().st_size > 0:
            logs.append((stdout_log, "brew service stdout"))

    # Also check daemon mode log
    daemon_log = get_log_file()
    if daemon_log.exists():
        logs.append((daemon_log, "daemon log"))

    # If nothing found, return expected paths
    if not logs:
        if is_brew_service_running():
            logs.append(
                (
                    get_brew_log_dir() / "vibe-check.error.log",
                    "brew service log (not created yet)",
                )
            )
        else:
            logs.append((get_log_file(), "daemon log (not created yet)"))

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

    # Check if authenticated, offer to login on first start
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
        print("\n☁️  Remote sync is not configured.")
        print("   This allows viewing your stats at vibecheck.wanderingstan.com")
        print("\nWould you like to authenticate now? (Y/n): ", end="", flush=True)
        try:
            response = input().strip().lower()
            if response in ["", "y", "yes"]:  # Default to yes (empty = Enter)
                cmd_auth_login(args)
                print()  # blank line after auth
        except (EOFError, KeyboardInterrupt):
            print("\nSkipping authentication. Run 'vibe-check auth login' later.")

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


def cmd_status(args):
    """Check vibe-check process status."""
    print(f"🧜 vibe-check v{VERSION}")
    print("")

    pid = is_running()
    is_brew_service = is_homebrew_service_running()
    is_systemd = is_systemd_service_running()

    if pid:
        if is_brew_service:
            print(f"✅ vibe-check is running as Homebrew service (PID: {pid})")
            print("   Auto-starts on boot: yes")
        elif is_systemd:
            print(f"✅ vibe-check is running as systemd service (PID: {pid})")
            print("   Auto-starts on login: yes")
        else:
            print(f"✅ vibe-check process is running (PID: {pid})")
            if is_homebrew_service():
                print("   Auto-starts on boot: no (use 'vibe-check start' to enable)")
            elif is_systemd_service():
                print("   Auto-starts on login: no (use 'vibe-check start' to enable)")
        # Show process info if possible
        try:
            result = subprocess.run(
                ["ps", "-p", str(pid), "-o", "pid,etime,command"],
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                print(result.stdout)
        except Exception:
            pass
    else:
        print("⚠️  vibe-check process is not running")
        print("   To start: vibe-check start")

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
            print(f"   {prefix:8}  {resolved_log} ({size_str})")
        else:
            print(f"   {prefix:8}  {log_path} ({description})")

    # PID file (resolve symlinks)
    pid_path = get_pid_file()
    if pid_path.exists():
        print(f"   PID:      {pid_path.resolve()}")
    else:
        print(f"   PID:      {pid_path} (not created)")

    # Local backup status
    print("\n💾 Local backup:")
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
                        print(f"   Last sync: {last_sync_time}")

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
    print("\n🔌 Claude Integration:")

    # MCP Plugin status
    mcp_installed = is_mcp_plugin_installed()
    if mcp_installed:
        print("   MCP:    ✅ Installed")
    else:
        print("   MCP:    ❌ Not installed")

    # Skills status
    skills_dir = Path.home() / ".claude" / "skills"
    # Skills are installed as directories with SKILL.md inside (vibe-check-* prefix)
    skills_to_check = [
        "vibe-check-stats",
        "vibe-check-search",
        "vibe-check-analyze-tools",
        "vibe-check-recent",
        "vibe-check-view-stats",
        "vibe-check-session-id",
        "vibe-check-share",
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
    if not mcp_installed or (skills_dir.exists() and len([s for s in skills_to_check if skill_installed(s)]) < len(skills_to_check)):
        print("   To install: run 'vibe-check start'")


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
            hooks = [h for h in hooks if not any(
                "session-tracker" in cmd.get("command", "") or "vibe-check" in cmd.get("command", "")
                for cmd in h.get("hooks", [])
            )]
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
  start         Start the vibe-check process in background
  stop          Stop the background process
  restart       Restart vibe-check process
  status        Check if vibe-check process is running
  logs          View vibe-check logs
  uninstall     Remove vibe-check data and Claude Code skills
  auth login    Authenticate with the vibe-check server
  auth status   Show current authentication status
  auth logout   Remove stored API key
  (no command)  Show status if running, or prompt to start

Examples:
  vibe-check                    # Show status or prompt to start
  vibe-check auth login         # Authenticate with the server
  vibe-check start              # Start in background
  vibe-check stop               # Stop background monitor
  vibe-check status             # Check status
  vibe-check logs               # View logs
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

    # Uninstall command
    parser_uninstall = subparsers.add_parser(
        "uninstall", help="Remove vibe-check data and Claude Code skills"
    )
    parser_uninstall.set_defaults(func=cmd_uninstall)

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
