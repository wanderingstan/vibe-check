"""
Database connection handling for vibe-check MCP server.

Uses read-only mode to avoid locks with the running monitor.
"""

import sqlite3
from pathlib import Path
from typing import Optional, List, Dict, Any
import os


def find_database_path() -> Optional[Path]:
    """
    Find the vibe-check database in standard locations.

    Returns the first valid database path found, or None.
    """
    # Check VIBE_CHECK_DB environment variable first
    env_path = os.environ.get("VIBE_CHECK_DB")
    if env_path:
        path = Path(env_path).expanduser()
        if path.exists():
            return path

    # Locations to check, in priority order
    locations = [
        Path.home() / ".vibe-check" / "vibe_check.db",
        Path("/opt/homebrew/var/vibe-check/vibe_check.db"),
        Path.home() / "Developer" / "vibe-check" / "vibe_check.db",
        Path.home() / "Developer" / "vibe-check" / "data" / "vibe_check.db",
    ]

    for path in locations:
        if path.exists():
            return path

    return None


def get_db_connection() -> sqlite3.Connection:
    """
    Get a read-only SQLite connection to the vibe-check database.

    Uses file URI mode with ?mode=ro to prevent locks.

    Raises:
        FileNotFoundError: If database cannot be found
    """
    db_path = find_database_path()

    if not db_path:
        raise FileNotFoundError(
            "Could not find vibe-check database. Checked:\n"
            "  - ~/.vibe-check/vibe_check.db\n"
            "  - /opt/homebrew/var/vibe-check/vibe_check.db\n"
            "  - ~/Developer/vibe-check/vibe_check.db\n"
            "\nIs vibe-check installed and running?"
        )

    # Use read-only URI mode to avoid database locks
    uri = f"file:{db_path}?mode=ro"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row  # Enable dict-like access

    return connection


def execute_query(query: str, params: tuple = ()) -> List[Dict[str, Any]]:
    """
    Execute a read-only query and return results as list of dicts.
    """
    conn = get_db_connection()
    try:
        cursor = conn.execute(query, params)
        rows = cursor.fetchall()
        return [dict(row) for row in rows]
    finally:
        conn.close()


def execute_scalar(query: str, params: tuple = ()) -> Any:
    """
    Execute a query and return single scalar value.
    """
    conn = get_db_connection()
    try:
        cursor = conn.execute(query, params)
        row = cursor.fetchone()
        return row[0] if row else None
    finally:
        conn.close()
