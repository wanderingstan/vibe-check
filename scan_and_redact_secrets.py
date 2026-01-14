#!/usr/bin/env python3
"""
Retroactive Secret Scanner for MySQL Database

This script scans the remote MySQL database for secrets in conversation messages
and redacts them by replacing the message text with "<SECRET REDACTED>".

Usage:
    python scan_and_redact_secrets.py --config server-php/config.json [--dry-run] [--limit N]

Arguments:
    --config    Path to MySQL config file (default: server-php/config.json)
    --dry-run   Show what would be changed without making changes
    --limit     Maximum number of records to scan (default: all)
"""

import argparse
import json
import sys
from pathlib import Path

try:
    import pymysql
except ImportError:
    print("Error: pymysql is required. Install with: pip install pymysql")
    sys.exit(1)

from secret_detector import contains_secrets, get_secret_types


def load_config(config_path: Path) -> dict:
    """Load MySQL configuration from file."""
    if not config_path.exists():
        print(f"Error: Config file not found: {config_path}")
        sys.exit(1)

    with open(config_path, "r") as f:
        config = json.load(f)

    if "mysql" not in config:
        print("Error: MySQL configuration not found in config file")
        sys.exit(1)

    return config["mysql"]


def connect_to_mysql(config: dict):
    """Connect to MySQL database."""
    try:
        connection = pymysql.connect(
            host=config["host"],
            user=config["user"],
            password=config["password"],
            database=config["database"],
            charset="utf8mb4",
            cursorclass=pymysql.cursors.DictCursor,
        )
        return connection
    except pymysql.Error as e:
        print(f"Error connecting to MySQL: {e}")
        sys.exit(1)


def scan_and_redact(connection, dry_run: bool = True, limit: int = None):
    """
    Scan database for secrets and redact them.

    Args:
        connection: MySQL connection
        dry_run: If True, show changes without applying them
        limit: Maximum number of records to scan
    """
    cursor = connection.cursor()

    # Query to get all message events
    query = """
        SELECT id, file_name, line_number, event_data, user_name
        FROM conversation_events
        WHERE event_type = 'message'
        ORDER BY id ASC
    """

    if limit:
        query += f" LIMIT {limit}"

    print(f"\nScanning database for secrets...")
    print(f"Mode: {'DRY RUN (no changes will be made)' if dry_run else 'LIVE (changes will be applied)'}")
    print("-" * 70)

    cursor.execute(query)
    records = cursor.fetchall()

    print(f"Found {len(records)} message records to scan\n")

    secrets_found = 0
    records_to_update = []

    for record in records:
        record_id = record["id"]
        file_name = record["file_name"]
        line_number = record["line_number"]
        event_data = json.loads(record["event_data"])

        # Check if this is a message event with text content
        if event_data.get("type") != "message":
            continue

        message = event_data.get("message", {})
        if not message or "content" not in message:
            continue

        content = message.get("content", [])
        if not isinstance(content, list):
            continue

        # Check each content block for secrets
        has_secret = False
        modified_event_data = json.loads(record["event_data"])  # Start with a fresh copy

        for i, block in enumerate(content):
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text", "")
                if text and contains_secrets(text):
                    has_secret = True
                    secret_types = get_secret_types(text)

                    print(f"🔴 SECRET FOUND in record ID {record_id}")
                    print(f"   File: {file_name}:{line_number}")
                    print(f"   User: {record['user_name']}")
                    print(f"   Types: {', '.join(secret_types)}")
                    print(f"   Text preview: {text[:100]}...")
                    print()

                    # Redact the message
                    modified_event_data["message"]["content"][i] = {
                        **block,
                        "text": "<SECRET REDACTED>"
                    }

        if has_secret:
            secrets_found += 1
            records_to_update.append({
                "id": record_id,
                "event_data": json.dumps(modified_event_data),
                "file_name": file_name,
                "line_number": line_number,
            })

    print("-" * 70)
    print(f"\nScan complete!")
    print(f"Records scanned: {len(records)}")
    print(f"Secrets found: {secrets_found}")

    if secrets_found == 0:
        print("\n✅ No secrets found! Database is clean.")
        cursor.close()
        return

    if dry_run:
        print(f"\n⚠️  DRY RUN MODE: No changes were made to the database.")
        print(f"Run without --dry-run to apply redactions.")
    else:
        print(f"\n🔄 Applying redactions to {len(records_to_update)} records...")

        update_query = """
            UPDATE conversation_events
            SET event_data = %s
            WHERE id = %s
        """

        for record in records_to_update:
            cursor.execute(update_query, (record["event_data"], record["id"]))
            print(f"   ✓ Updated record {record['id']}: {record['file_name']}:{record['line_number']}")

        connection.commit()
        print(f"\n✅ Successfully redacted {len(records_to_update)} records!")

    cursor.close()


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Scan MySQL database for secrets and redact them"
    )
    parser.add_argument(
        "--config",
        default="server-php/config.json",
        help="Path to MySQL config file (default: server-php/config.json)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be changed without making changes",
    )
    parser.add_argument(
        "--limit",
        type=int,
        help="Maximum number of records to scan (default: all)",
    )

    args = parser.parse_args()

    # Load configuration
    config_path = Path(args.config)
    mysql_config = load_config(config_path)

    # Connect to database
    print(f"Connecting to MySQL at {mysql_config['host']}...")
    connection = connect_to_mysql(mysql_config)
    print("✓ Connected successfully")

    try:
        # Scan and redact
        scan_and_redact(connection, dry_run=args.dry_run, limit=args.limit)
    finally:
        connection.close()
        print("\nDatabase connection closed.")


if __name__ == "__main__":
    main()
