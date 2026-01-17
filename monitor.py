#!/usr/bin/env python3
"""
Claude Code Conversation Monitor

Monitors .jsonl files in the Claude Code conversations directory and
sends new events to the Vibe Check API server.
"""

import argparse
import copy
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, Optional, Tuple

import requests
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler, FileModifiedEvent

import sqlite3

from secret_detector import redact_if_secret


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
    """Manages state tracking for file processing."""

    def __init__(self, state_file: str):
        self.state_file = Path(state_file)
        self.state: Dict[str, int] = {}
        self.load()

    def load(self):
        """Load state from file."""
        if self.state_file.exists():
            try:
                with open(self.state_file, "r") as f:
                    self.state = json.load(f)
                print(f"Loaded state: {len(self.state)} files tracked")
            except json.JSONDecodeError:
                print("Warning: Could not parse state file, starting fresh")
                self.state = {}
        else:
            print("No state file found, starting fresh")
            self.state = {}

    def save(self):
        """Save state to file."""
        with open(self.state_file, "w") as f:
            json.dump(self.state, f, indent=2)

    def get_last_line(self, filename: str) -> int:
        """Get the last processed line number for a file."""
        return self.state.get(filename, 0)

    def set_last_line(self, filename: str, line_number: int):
        """Set the last processed line number for a file."""
        self.state[filename] = line_number
        self.save()

    def skip_to_end(self, directory: Path, debug_filter_project: Optional[str] = None):
        """Fast-forward state to the end of all existing files without processing."""
        print("\nSkipping backlog - fast-forwarding to current position...")
        count = 0
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
                    self.set_last_line(filename, line_count)
                    print(f"  Skipped {line_count} lines in {filename}")
                    count += 1
            except Exception as e:
                print(f"  Error reading {filename}: {e}")

        print(
            f"Fast-forwarded {count} file(s). Monitoring will start from current position.\n"
        )


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
            print("SQLite recording is disabled")
            return

        try:
            # Expand path and create database
            self.db_path = Path(config["database_path"]).expanduser()
            self.db_path.parent.mkdir(parents=True, exist_ok=True)

            self.connect()
            self.create_schema()
            print(f"Connected to SQLite database: {self.db_path}")
        except Exception as e:
            print(f"Error initializing SQLite: {e}")
            print(
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
            print(f"SQLite error: {e}")
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
            print("Remote API recording is disabled")

    def test_connection(self):
        """Test API connection."""
        try:
            # Try the configured URL first
            response = self.session.get(f"{self.api_endpoint}/health")
            response.raise_for_status()
            print(f"Connected to API server: {self.api_endpoint}")
        except requests.RequestException as e:
            # If that fails and URL doesn't already have api.php, try adding it
            if "/api.php" not in self.api_endpoint:
                try:
                    self.api_endpoint = f"{self.api_url}/api.php"
                    response = self.session.get(f"{self.api_endpoint}/health")
                    response.raise_for_status()
                    print(f"Connected to API server: {self.api_endpoint}")
                    return
                except requests.RequestException:
                    pass

            print(f"Error connecting to API: {e}")
            sys.exit(1)

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

            print(f"Processing {len(new_lines)} new line(s) from {filename}")

            for idx, line in enumerate(new_lines):
                line_number = last_line + idx + 1
                line = line.strip()

                if not line:
                    continue

                try:
                    # Parse JSON
                    event_data = json.loads(line)

                    # Insert into database
                    self.insert_event(filename, line_number, event_data)

                    # Update state
                    self.state_manager.set_last_line(filename, line_number)

                except json.JSONDecodeError as e:
                    print(f"Warning: Invalid JSON at {filename}:{line_number}: {e}")
                    # Still update state to skip this line
                    self.state_manager.set_last_line(filename, line_number)
                except requests.RequestException as e:
                    print(f"API error at {filename}:{line_number}: {e}")
                    # Don't update state so we retry later
                    break

        except Exception as e:
            print(f"Error processing {file_path}: {e}")

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
        print(f"  [DEBUG] Event type: {event_type}")

        # Check if this is a user or assistant message with text content
        if event_type in ("user", "assistant", "message"):
            message = event_data.get("message", {})
            print(f"  [DEBUG] Message found: {bool(message)}")
            if message and "content" in message:
                content = message.get("content", [])
                print(
                    f"  [DEBUG] Content blocks: {len(content) if isinstance(content, list) else 0}"
                )
                if isinstance(content, list):
                    # Check each content block
                    for i, block in enumerate(content):
                        if isinstance(block, dict) and block.get("type") == "text":
                            text = block.get("text", "")
                            print(
                                f"  [DEBUG] Block {i} text length: {len(text)}, preview: {text[:100]}"
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
                                    print(
                                        f"  ⚠️  Secret detected and redacted in message"
                                    )
                                else:
                                    print(f"  [DEBUG] No secrets found in block {i}")

        return event_data

    def insert_event(self, filename: str, line_number: int, event_data: dict):
        """Insert an event via API and SQLite (if enabled)."""
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
                print(f"  API error {filename}:{line_number}: {e}")

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
            status_msg = f"  Inserted: {filename}:{line_number} → {', '.join(status)}"
            if git_info:
                status_msg += f" [{', '.join(git_info)}]"
            print(status_msg)

        # Only raise error if both failed (or if neither is enabled)
        if not api_success and not sqlite_success:
            if not self.api_enabled and not (
                self.sqlite_manager and self.sqlite_manager.enabled
            ):
                raise requests.RequestException(
                    "Both API and SQLite are disabled - at least one must be enabled"
                )
            raise requests.RequestException("Both API and SQLite insertion failed")

    def on_modified(self, event):
        """Handle file modification events."""
        if event.is_directory:
            return

        file_path = Path(event.src_path)
        if file_path.suffix == ".jsonl":
            print(f"\nDetected change: {file_path.name}")
            self.process_file(file_path)

    def on_created(self, event):
        """Handle file creation events."""
        if event.is_directory:
            return

        file_path = Path(event.src_path)
        if file_path.suffix == ".jsonl":
            print(f"\nDetected new file: {file_path.name}")
            self.process_file(file_path)

    def process_existing_files(self, directory: Path):
        """Process all existing JSONL files on startup."""
        print("\nProcessing existing files...")
        for file_path in directory.glob("**/*.jsonl"):
            self.process_file(file_path)
        print("Finished processing existing files\n")


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


def get_pid_file() -> Path:
    """Get the path to the PID file."""
    # Use VIBE_CHECK_HOME if set (for Homebrew), otherwise use script directory
    if "VIBE_CHECK_HOME" in os.environ:
        return Path(os.environ["VIBE_CHECK_HOME"]) / ".monitor.pid"
    return Path(__file__).parent / ".monitor.pid"


def get_log_file() -> Path:
    """Get the path to the log file."""
    if "VIBE_CHECK_HOME" in os.environ:
        return Path(os.environ["VIBE_CHECK_HOME"]) / "monitor.log"
    return Path(__file__).parent / "monitor.log"


def is_running() -> Optional[int]:
    """Check if monitor is already running. Returns PID if running, None otherwise."""
    pid_file = get_pid_file()
    if not pid_file.exists():
        return None

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
            return None
    except (ValueError, FileNotFoundError):
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

    log_file = get_log_file()
    log_file.parent.mkdir(parents=True, exist_ok=True)

    with open(log_file, "a") as f:
        os.dup2(f.fileno(), sys.stdout.fileno())
        os.dup2(f.fileno(), sys.stderr.fileno())

    # Close stdin
    with open("/dev/null", "r") as f:
        os.dup2(f.fileno(), sys.stdin.fileno())


def cmd_start(args):
    """Start the monitor in daemon mode."""
    pid = is_running()
    if pid:
        print(f"✅ Monitor is already running (PID: {pid})")
        return

    print("🧜 Starting monitor in background...")

    # Daemonize the process
    daemonize()

    # Write PID file
    write_pid_file()

    # Set up signal handlers
    def signal_handler(signum, frame):
        print(f"\nReceived signal {signum}, stopping monitor...")
        remove_pid_file()
        sys.exit(0)

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    # Run the monitor
    print(f"Monitor started at {time.strftime('%Y-%m-%d %H:%M:%S')}")
    run_monitor(args)


def cmd_stop(args):
    """Stop the monitor daemon."""
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
            print("⚠️  Force killing monitor...")
            os.kill(pid, signal.SIGKILL)
            time.sleep(0.5)

        remove_pid_file()
        print("✅ Monitor stopped")
    except OSError as e:
        print(f"Error stopping monitor: {e}")
        remove_pid_file()


def cmd_restart(args):
    """Restart the monitor daemon."""
    cmd_stop(args)
    time.sleep(1)
    cmd_start(args)


def cmd_status(args):
    """Check monitor status."""
    pid = is_running()
    if pid:
        print(f"✅ Monitor is running (PID: {pid})")
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
        print("⚠️  Monitor is not running")
        sys.exit(1)


def cmd_logs(args):
    """View monitor logs."""
    log_file = get_log_file()

    if not log_file.exists():
        print(f"⚠️  No log file found at {log_file}")
        return

    # Show last 50 lines
    lines = args.lines if hasattr(args, 'lines') and args.lines else 50

    try:
        with open(log_file, "r") as f:
            all_lines = f.readlines()
            recent_lines = all_lines[-lines:]
            print(f"🧜 Last {len(recent_lines)} lines of {log_file}:\n")
            print("".join(recent_lines))
    except Exception as e:
        print(f"Error reading log file: {e}")


def run_monitor(args):
    """Run the monitor (extracted from main for daemon support)."""
    # Load configuration
    config_path = Path(__file__).parent / "config.json"
    if "VIBE_CHECK_HOME" in os.environ:
        config_path = Path(os.environ["VIBE_CHECK_HOME"]) / "config.json"

    if not config_path.exists():
        print(f"Error: Configuration file not found: {config_path}")
        print("Please create config.json with your API configuration")
        sys.exit(1)

    with open(config_path, "r") as f:
        config = json.load(f)

    # Expand paths
    conversation_dir = Path(config["monitor"]["conversation_dir"]).expanduser()

    if not conversation_dir.exists():
        print(f"Error: Conversation directory not found: {conversation_dir}")
        sys.exit(1)

    print(f"Monitoring directory: {conversation_dir}")

    # Check for Claude Code skills (unless skipped)
    if not args.skip_skills_check:
        check_claude_skills()

    # Debug filter
    debug_filter = config["monitor"].get("debug_filter_project")
    if debug_filter:
        print(f"DEBUG: Only processing project: {debug_filter}")

    # Initialize state manager
    state_file = Path(__file__).parent / config["monitor"]["state_file"]
    if "VIBE_CHECK_HOME" in os.environ:
        state_file = Path(os.environ["VIBE_CHECK_HOME"]) / "state.json"

    state_manager = StateManager(state_file)

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

    print("Monitoring for changes... (Press Ctrl+C to stop)")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\nStopping monitor...")
        observer.stop()

    observer.join()
    print("Monitor stopped")


def main():
    """Main entry point with subcommands."""
    parser = argparse.ArgumentParser(
        description="Claude Code Conversation Monitor",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Commands:
  start         Start the monitor in background
  stop          Stop the background monitor
  restart       Restart the monitor
  status        Check if monitor is running
  logs          View monitor logs
  (no command)  Run monitor in foreground (default)

Examples:
  vibe-check                    # Run in foreground
  vibe-check start              # Start in background
  vibe-check stop               # Stop background monitor
  vibe-check status             # Check status
  vibe-check logs               # View logs
  vibe-check --skip-backlog     # Run foreground, skip existing conversations
        """
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

    # Create subparsers
    subparsers = parser.add_subparsers(dest="command", help="Command to execute")

    # Start command
    parser_start = subparsers.add_parser("start", help="Start monitor in background")
    parser_start.set_defaults(func=cmd_start)

    # Stop command
    parser_stop = subparsers.add_parser("stop", help="Stop background monitor")
    parser_stop.set_defaults(func=cmd_stop)

    # Restart command
    parser_restart = subparsers.add_parser("restart", help="Restart background monitor")
    parser_restart.set_defaults(func=cmd_restart)

    # Status command
    parser_status = subparsers.add_parser("status", help="Check monitor status")
    parser_status.set_defaults(func=cmd_status)

    # Logs command
    parser_logs = subparsers.add_parser("logs", help="View monitor logs")
    parser_logs.add_argument(
        "-n", "--lines",
        type=int,
        default=50,
        help="Number of lines to show (default: 50)"
    )
    parser_logs.set_defaults(func=cmd_logs)

    # Parse arguments
    args = parser.parse_args()

    # If a subcommand was specified, run it
    if hasattr(args, "func"):
        args.func(args)
    else:
        # No subcommand = run in foreground
        run_monitor(args)


if __name__ == "__main__":
    main()
