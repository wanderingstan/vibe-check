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

    def insert_event(
        self,
        filename: str,
        line_number: int,
        event_data: dict,
        git_remote_url: Optional[str] = None,
        git_commit_hash: Optional[str] = None,
    ) -> bool:
        """Insert an event into the SQLite database."""
        if not self.enabled:
            return False

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

            return True

        except sqlite3.Error as e:
            logger.error(f"SQLite error: {e}")
            return False

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

            # Track success counts
            api_success_count = 0
            sqlite_success_count = 0
            processed_count = 0
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

                    # Insert into database
                    api_success, sqlite_success = self.insert_event(filename, line_number, event_data)
                    processed_count += 1
                    if api_success:
                        api_success_count += 1
                    if sqlite_success:
                        sqlite_success_count += 1

                    # Update state
                    self.state_manager.set_last_line(filename, line_number)

                except json.JSONDecodeError as e:
                    logger.warning(f"Invalid JSON at {filename}:{line_number}: {e}")
                    # Still update state to skip this line
                    self.state_manager.set_last_line(filename, line_number)
                    skipped_count += 1
                except requests.RequestException as e:
                    logger.error(f"API error at {filename}:{line_number}: {e}")
                    # Don't update state so we retry later
                    break

            # Log summary of what was written
            if processed_count > 0:
                destinations = []
                if self.api_enabled:
                    destinations.append(f"remote:{api_success_count}/{processed_count}")
                if self.sqlite_manager and self.sqlite_manager.enabled:
                    destinations.append(f"local:{sqlite_success_count}/{processed_count}")
                logger.info(f"Write summary for {filename}: {', '.join(destinations)}")

                # Warn if remote is enabled but failing
                if self.api_enabled and api_success_count == 0 and processed_count > 0:
                    logger.warning(f"Remote API enabled but 0/{processed_count} events written to server!")
                    logger.warning(f"Check API connection: {self.api_endpoint}")

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

    def insert_event(self, filename: str, line_number: int, event_data: dict) -> Tuple[bool, bool]:
        """Insert an event via API and SQLite (if enabled).

        Returns:
            Tuple of (api_success, sqlite_success) booleans
        """
        api_success = False
        sqlite_success = False

        # Get git info from working directory if available
        git_remote_url = None
        git_commit_hash = None
        working_dir = event_data.get("cwd")
        if working_dir:
            git_remote_url, git_commit_hash = get_git_info(Path(working_dir))

        # Try API if enabled (with redaction for remote storage)
        if self.api_enabled:
            try:
                # Create redacted version for remote API
                redacted_event_data = self.redact_secrets_from_event(event_data)

                response = self.session.post(
                    f"{self.api_endpoint}/events",
                    json={
                        "file_name": filename,
                        "line_number": line_number,
                        "event_data": redacted_event_data,
                        "git_remote_url": git_remote_url,
                        "git_commit_hash": git_commit_hash,
                    },
                )
                response.raise_for_status()
                api_success = True
            except requests.RequestException as e:
                logger.error(f"API error {filename}:{line_number}: {e}")

        # Try SQLite if enabled (with original unredacted data for local storage)
        if self.sqlite_manager and self.sqlite_manager.enabled:
            sqlite_success = self.sqlite_manager.insert_event(
                filename, line_number, event_data, git_remote_url, git_commit_hash
            )

        # Report success
        if api_success or sqlite_success:
            status = []
            if api_success:
                status.append("API")
            if sqlite_success:
                status.append("SQLite")
            git_info = []
            if git_remote_url:
                # Extract repo name from URL
                repo_name = git_remote_url.split("/")[-1].replace(".git", "")
                git_info.append(f"repo:{repo_name}")
            if git_commit_hash:
                git_info.append(f"commit:{git_commit_hash[:7]}")
            status_msg = f"Inserted: {filename}:{line_number} → {', '.join(status)}"
            if git_info:
                status_msg += f" [{', '.join(git_info)}]"
            logger.info(status_msg)

        # Only raise error if both failed (or if neither is enabled)
        if not api_success and not sqlite_success:
            if not self.api_enabled and not (
                self.sqlite_manager and self.sqlite_manager.enabled
            ):
                raise requests.RequestException(
                    "Both API and SQLite are disabled - at least one must be enabled"
                )
            raise requests.RequestException("Both API and SQLite insertion failed")

        return api_success, sqlite_success

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

    def process_existing_files(self, directory: Path):
        """Process all existing JSONL files on startup."""
        logger.info("Processing existing files...")
        for file_path in directory.glob("**/*.jsonl"):
            self.process_file(file_path)
        logger.info("Finished processing existing files")


def check_claude_skills():
    """Check if Claude Code skills are installed and prompt to install if not."""
    skills_dir = Path.home() / ".claude" / "skills"
    skills_to_check = [
        "claude-stats.md",
        "search-conversations.md",
        "analyze-tools.md",
        "recent-work.md",
        "view-stats.md",
    ]

    # Check if any skills are missing
    missing_skills = []
    for skill in skills_to_check:
        if not (skills_dir / skill).exists():
            missing_skills.append(skill)

    # If all skills are installed, nothing to do
    if not missing_skills:
        return

    # Check if we're in the vibe-check directory with the installer
    script_dir = Path(__file__).parent
    installer_path = script_dir / "claude-skills" / "install-skills.sh"

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

    For Homebrew installations: uses VIBE_CHECK_HOME environment variable
    For manual installations: uses <script_dir>/data/
    """
    if "VIBE_CHECK_HOME" in os.environ:
        return Path(os.environ["VIBE_CHECK_HOME"])
    return Path(__file__).parent / "data"


def get_pid_file() -> Path:
    """Get the path to the PID file."""
    return get_data_dir() / ".monitor.pid"


def get_log_file() -> Path:
    """Get the path to the log file."""
    return get_data_dir() / "monitor.log"


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
    try:
        result = subprocess.run(
            ["pgrep", "-f", "vibe-check.py"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and result.stdout.strip():
            # Get first PID from output
            pids = result.stdout.strip().split("\n")
            return int(pids[0])
    except Exception:
        pass

    return None


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

    # Set up signal handlers
    def signal_handler(signum, frame):
        logger.info(f"Received signal {signum}, stopping monitor...")
        remove_pid_file()
        sys.exit(0)

    if getattr(args, 'foreground', False):
        # Foreground mode for systemd/launchd
        print("🧜 Starting monitor in foreground...")

        # Set up logging to stdout for foreground mode
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s - %(levelname)s - %(message)s",
            handlers=[logging.StreamHandler(sys.stdout)]
        )

        write_pid_file()
        signal.signal(signal.SIGTERM, signal_handler)
        signal.signal(signal.SIGINT, signal_handler)

        logger.info("Monitor started (foreground mode)")
        run_monitor(args)
    else:
        # Background/daemon mode
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
    pid = is_running()
    if not pid:
        print("⚠️  Monitor is not running")
        return

    # Check if running as a brew service (launchd will restart it if we just kill it)
    try:
        result = subprocess.run(
            ["brew", "services", "list"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and "vibe-check" in result.stdout:
            # Parse the output to check if it's started
            for line in result.stdout.splitlines():
                if "vibe-check" in line and "started" in line.lower():
                    print("ℹ️  vibe-check is running as a Homebrew service.")
                    print("   Use: brew services stop vibe-check")
                    return
    except FileNotFoundError:
        # brew command not found, not a brew installation
        pass

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
            if "sqlite" in config and config["sqlite"].get("enabled", True):
                return Path(config["sqlite"]["database_path"]).expanduser()
        except (json.JSONDecodeError, KeyError):
            pass
    return None


def cmd_status(args):
    """Check vibe-check process status."""
    pid = is_running()
    if pid:
        print(f"✅ vibe-check process is running (PID: {pid})")
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

    # Show file locations
    print("\n📁 File locations:")

    # Config file
    config_path = get_config_path()
    if config_path.exists():
        print(f"   Config:   {config_path}")
    else:
        print(f"   Config:   {config_path} (not found)")

    # SQLite database
    db_path = get_sqlite_db_path()
    if db_path:
        if db_path.exists():
            # Show file size
            size_bytes = db_path.stat().st_size
            if size_bytes < 1024:
                size_str = f"{size_bytes} B"
            elif size_bytes < 1024 * 1024:
                size_str = f"{size_bytes / 1024:.1f} KB"
            else:
                size_str = f"{size_bytes / (1024 * 1024):.1f} MB"
            print(f"   Database: {db_path} ({size_str})")
        else:
            print(f"   Database: {db_path} (not created yet)")
    else:
        print("   Database: (SQLite disabled or not configured)")

    # Log file
    log_path = get_log_file()
    if log_path.exists():
        size_bytes = log_path.stat().st_size
        if size_bytes < 1024:
            size_str = f"{size_bytes} B"
        elif size_bytes < 1024 * 1024:
            size_str = f"{size_bytes / 1024:.1f} KB"
        else:
            size_str = f"{size_bytes / (1024 * 1024):.1f} MB"
        print(f"   Log:      {log_path} ({size_str})")
    else:
        print(f"   Log:      {log_path} (not created yet)")

    # PID file
    pid_path = get_pid_file()
    if pid_path.exists():
        print(f"   PID:      {pid_path}")
    else:
        print(f"   PID:      {pid_path} (not created)")

    # Exit with error if not running
    if not pid:
        sys.exit(1)


def cmd_logs(args):
    """View vibe-check process logs."""
    log_file = get_log_file()

    if not log_file.exists():
        print(f"⚠️  No log file found at {log_file}")
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
            "sqlite": {"enabled": True, "database_path": "~/.vibe-check/vibe_check.db"}
        }
    else:
        with open(config_path, "r") as f:
            config = json.load(f)
        api_url = config.get("api", {}).get("url", "") or DEFAULT_API_URL

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
            timeout=10
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
                    timeout=10
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
                        print("\n🎉 You're all set! Run 'vibe-check start' to begin monitoring.")
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
        logger.error(f"Configuration file not found: {config_path}")
        logger.error("Please create config.json in the data directory")
        logger.error(f"Expected location: {config_path}")
        sys.exit(1)

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
        "--foreground", "-f", action="store_true",
        help="Run in foreground (for systemd/launchd)"
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

    # Auth command with subcommands
    parser_auth = subparsers.add_parser(
        "auth", help="Authentication commands"
    )
    auth_subparsers = parser_auth.add_subparsers(dest="auth_command", help="Auth command")

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
