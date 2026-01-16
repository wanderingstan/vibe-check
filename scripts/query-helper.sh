#!/bin/bash
# Helper script to query vibe-check database
# Uses read-only mode to avoid locks when monitor is running

DB_PATH="${1:-$HOME/Developer/vibe-check/vibe_check.db}"

if [ ! -f "$DB_PATH" ]; then
    echo "Error: Database not found at $DB_PATH"
    exit 1
fi

# Use read-only mode to avoid database locks
sqlite3 "file:${DB_PATH}?mode=ro" "${@:2}"
