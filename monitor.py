#!/usr/bin/env python3
"""
Claude Code Conversation Monitor

Monitors .jsonl files in the Claude Code conversations directory and
sends new events to the Vibe Check API server.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, Optional, Tuple

import requests
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler, FileModifiedEvent

import sqlite3


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
            ['git', '-C', str(directory), 'remote', 'get-url', 'origin'],
            capture_output=True,
            text=True,
            timeout=1
        )
        remote_url = result.stdout.strip() if result.returncode == 0 else None

        # Get commit hash
        result = subprocess.run(
            ['git', '-C', str(directory), 'rev-parse', 'HEAD'],
            capture_output=True,
            text=True,
            timeout=1
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
                with open(self.state_file, 'r') as f:
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
        with open(self.state_file, 'w') as f:
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
        for file_path in directory.glob('**/*.jsonl'):
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
                with open(file_path, 'r', encoding='utf-8') as f:
                    line_count = sum(1 for _ in f)

                if line_count > 0:
                    self.set_last_line(filename, line_count)
                    print(f"  Skipped {line_count} lines in {filename}")
                    count += 1
            except Exception as e:
                print(f"  Error reading {filename}: {e}")

        print(f"Fast-forwarded {count} file(s). Monitoring will start from current position.\n")


class SQLiteManager:
    """Manages SQLite database connections and operations."""

    def __init__(self, config: dict):
        """Initialize SQLite manager with configuration."""
        self.config = config
        self.enabled = config.get('enabled', False)
        self.user_name = config.get('user_name', 'unknown')
        self.connection = None
        self.cursor = None
        self.db_path = None

        if not self.enabled:
            print("SQLite recording is disabled")
            return

        try:
            # Expand path and create database
            self.db_path = Path(config['database_path']).expanduser()
            self.db_path.parent.mkdir(parents=True, exist_ok=True)

            self.connect()
            self.create_schema()
            print(f"Connected to SQLite database: {self.db_path}")
        except Exception as e:
            print(f"Error initializing SQLite: {e}")
            print("SQLite recording will be disabled. Events will still be sent to API.")
            self.enabled = False

    def connect(self):
        """Establish SQLite connection."""
        self.connection = sqlite3.connect(str(self.db_path), check_same_thread=False)
        self.cursor = self.connection.cursor()

    def create_schema(self):
        """Create database schema if it doesn't exist."""
        self.cursor.execute("""
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
        """)

        # Create indexes
        self.cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_file_name ON conversation_events(file_name)
        """)
        self.cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_user_name ON conversation_events(user_name)
        """)
        self.cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_inserted_at ON conversation_events(inserted_at)
        """)
        self.cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_event_type ON conversation_events(event_type)
        """)
        self.cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_event_message ON conversation_events(event_message)
        """)
        self.cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_event_git_branch ON conversation_events(event_git_branch)
        """)
        self.cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_event_session_id ON conversation_events(event_session_id)
        """)
        self.cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_event_uuid ON conversation_events(event_uuid)
        """)
        self.cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_git_remote_url ON conversation_events(git_remote_url)
        """)
        self.cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_git_commit_hash ON conversation_events(git_commit_hash)
        """)

        self.connection.commit()

    def insert_event(self, filename: str, line_number: int, event_data: dict,
                     git_remote_url: Optional[str] = None, git_commit_hash: Optional[str] = None) -> bool:
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
            self.cursor.execute(query, (filename, line_number, event_json, self.user_name,
                                       git_remote_url, git_commit_hash))
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

    def __init__(self, api_config: dict, state_manager: StateManager, base_dir: Path, sqlite_manager: Optional[SQLiteManager] = None, debug_filter_project: Optional[str] = None):
        self.api_url = api_config['url']
        self.api_key = api_config['api_key']
        self.state_manager = state_manager
        self.base_dir = base_dir
        self.sqlite_manager = sqlite_manager
        self.debug_filter_project = debug_filter_project
        self.session = requests.Session()
        self.session.headers.update({
            'X-API-Key': self.api_key,
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'User-Agent': 'VibeCheck-Monitor/1.0'
        })

        # Auto-detect if we need /api.php in the URL
        self.api_endpoint = self.api_url
        self.test_connection()

    def test_connection(self):
        """Test API connection."""
        try:
            # Try the configured URL first
            response = self.session.get(f"{self.api_endpoint}/health")
            response.raise_for_status()
            print(f"Connected to API server: {self.api_endpoint}")
        except requests.RequestException as e:
            # If that fails and URL doesn't already have api.php, try adding it
            if '/api.php' not in self.api_endpoint:
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
        if not file_path.suffix == '.jsonl':
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
            with open(file_path, 'r', encoding='utf-8') as f:
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

    def insert_event(self, filename: str, line_number: int, event_data: dict):
        """Insert an event via API and SQLite (if enabled)."""
        api_success = False
        sqlite_success = False

        # Get git info from working directory if available
        git_remote_url = None
        git_commit_hash = None
        working_dir = event_data.get('cwd')
        if working_dir:
            git_remote_url, git_commit_hash = get_git_info(Path(working_dir))

        # Try API first
        try:
            response = self.session.post(
                f"{self.api_endpoint}/events",
                json={
                    'file_name': filename,
                    'line_number': line_number,
                    'event_data': event_data,
                    'git_remote_url': git_remote_url,
                    'git_commit_hash': git_commit_hash
                }
            )
            response.raise_for_status()
            api_success = True
        except requests.RequestException as e:
            print(f"  API error {filename}:{line_number}: {e}")

        # Try SQLite if enabled
        if self.sqlite_manager and self.sqlite_manager.enabled:
            sqlite_success = self.sqlite_manager.insert_event(filename, line_number, event_data,
                                                             git_remote_url, git_commit_hash)

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
                repo_name = git_remote_url.split('/')[-1].replace('.git', '')
                git_info.append(f"repo:{repo_name}")
            if git_commit_hash:
                git_info.append(f"commit:{git_commit_hash[:7]}")
            status_msg = f"  Inserted: {filename}:{line_number} → {', '.join(status)}"
            if git_info:
                status_msg += f" [{', '.join(git_info)}]"
            print(status_msg)

        # Only raise error if both failed
        if not api_success and not sqlite_success:
            raise requests.RequestException("Both API and SQLite insertion failed")

    def on_modified(self, event):
        """Handle file modification events."""
        if event.is_directory:
            return

        file_path = Path(event.src_path)
        if file_path.suffix == '.jsonl':
            print(f"\nDetected change: {file_path.name}")
            self.process_file(file_path)

    def on_created(self, event):
        """Handle file creation events."""
        if event.is_directory:
            return

        file_path = Path(event.src_path)
        if file_path.suffix == '.jsonl':
            print(f"\nDetected new file: {file_path.name}")
            self.process_file(file_path)

    def process_existing_files(self, directory: Path):
        """Process all existing JSONL files on startup."""
        print("\nProcessing existing files...")
        for file_path in directory.glob('**/*.jsonl'):
            self.process_file(file_path)
        print("Finished processing existing files\n")


def check_claude_skills():
    """Check if Claude Code skills are installed and prompt to install if not."""
    skills_dir = Path.home() / '.claude' / 'skills'
    skills_to_check = [
        'claude-stats.md',
        'search-conversations.md',
        'analyze-tools.md',
        'recent-work.md'
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
    installer_path = script_dir / 'claude-skills' / 'install-skills.sh'

    if not installer_path.exists():
        # Installer not available (maybe installed via package manager)
        return

    # Skills are missing and installer is available - prompt user
    print("\n" + "="*70)
    print("📚 Claude Code Skills Available!")
    print("="*70)
    print("\nVibe Check includes Claude Code skills that let you query your")
    print("conversation history using natural language!")
    print(f"\nMissing skills: {len(missing_skills)}/{len(skills_to_check)}")
    print("\nOnce installed, you can ask Claude:")
    print("  • 'claude stats' - View usage statistics")
    print("  • 'what have I been working on?' - See recent sessions")
    print("  • 'search my conversations for X' - Search history")
    print("  • 'what tools do I use most?' - Analyze tool usage")
    print("\nWould you like to install the skills now? (y/n): ", end='', flush=True)

    try:
        response = input().strip().lower()
        if response in ['y', 'yes']:
            print("\nInstalling skills...")
            result = subprocess.run(
                [str(installer_path)],
                cwd=str(script_dir),
                capture_output=False
            )
            if result.returncode == 0:
                print("\n✅ Skills installed successfully!")
            else:
                print("\n⚠️  Installation had some issues. You can install manually later:")
                print(f"   {installer_path}")
        else:
            print("\nSkipped. You can install skills later by running:")
            print(f"  {installer_path}")
    except (EOFError, KeyboardInterrupt):
        print("\n\nSkipped. You can install skills later by running:")
        print(f"  {installer_path}")

    print("="*70)
    print()


def main():
    """Main entry point."""
    # Parse command-line arguments
    parser = argparse.ArgumentParser(
        description='Monitor Claude Code conversation files and send events to Vibe Check API'
    )
    parser.add_argument(
        '--skip-backlog',
        action='store_true',
        help='Skip existing conversation history and start monitoring from current position'
    )
    parser.add_argument(
        '--skip-skills-check',
        action='store_true',
        help='Skip checking for Claude Code skills installation'
    )
    args = parser.parse_args()

    # Load configuration
    config_path = Path(__file__).parent / 'config.json'
    if not config_path.exists():
        print(f"Error: Configuration file not found: {config_path}")
        print("Please create config.json with your API configuration")
        sys.exit(1)

    with open(config_path, 'r') as f:
        config = json.load(f)

    # Expand paths
    conversation_dir = Path(config['monitor']['conversation_dir']).expanduser()

    if not conversation_dir.exists():
        print(f"Error: Conversation directory not found: {conversation_dir}")
        sys.exit(1)

    print(f"Monitoring directory: {conversation_dir}")

    # Check for Claude Code skills (unless skipped)
    if not args.skip_skills_check:
        check_claude_skills()

    # Debug filter
    debug_filter = config['monitor'].get('debug_filter_project')
    if debug_filter:
        print(f"DEBUG: Only processing project: {debug_filter}")

    # Initialize state manager
    state_file = Path(__file__).parent / config['monitor']['state_file']
    state_manager = StateManager(state_file)

    # Handle skip-backlog flag
    if args.skip_backlog:
        state_manager.skip_to_end(conversation_dir, debug_filter)

    # Initialize SQLite manager
    sqlite_manager = None
    if 'sqlite' in config:
        sqlite_manager = SQLiteManager(config['sqlite'])

    # Initialize monitor
    event_handler = ConversationMonitor(config['api'], state_manager, conversation_dir, sqlite_manager, debug_filter)

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


if __name__ == '__main__':
    main()
