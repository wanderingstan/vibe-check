#!/usr/bin/env python3
"""
Claude Code Conversation Monitor

Monitors .jsonl files in the Claude Code conversations directory and
sends new events to the Vibe Check API server.
"""

import json
import os
import sys
import time
from pathlib import Path
from typing import Dict, Optional

import requests
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler, FileModifiedEvent


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


class ConversationMonitor(FileSystemEventHandler):
    """Handles file system events for conversation files."""

    def __init__(self, api_config: dict, state_manager: StateManager, base_dir: Path, debug_filter_project: Optional[str] = None):
        self.api_url = api_config['url']
        self.api_key = api_config['api_key']
        self.state_manager = state_manager
        self.base_dir = base_dir
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
        """Insert an event via API."""
        try:
            response = self.session.post(
                f"{self.api_endpoint}/events",
                json={
                    'file_name': filename,
                    'line_number': line_number,
                    'event_data': event_data
                }
            )
            response.raise_for_status()
            print(f"  Inserted: {filename}:{line_number}")
        except requests.RequestException as e:
            print(f"  Failed to insert {filename}:{line_number}: {e}")
            raise

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


def main():
    """Main entry point."""
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

    # Debug filter
    debug_filter = config['monitor'].get('debug_filter_project')
    if debug_filter:
        print(f"DEBUG: Only processing project: {debug_filter}")

    # Initialize state manager
    state_file = Path(__file__).parent / config['monitor']['state_file']
    state_manager = StateManager(state_file)

    # Initialize monitor
    event_handler = ConversationMonitor(config['api'], state_manager, conversation_dir, debug_filter)

    # Process existing files first
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
