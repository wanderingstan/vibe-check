#!/bin/bash
# Helper script to query vibe-check database
# Uses read-only mode to avoid locks when monitor is running

# Use VIBE_CHECK_DB env var if set, otherwise first arg, otherwise default
DB_PATH="${VIBE_CHECK_DB:-${1:-$HOME/Developer/vibe-check/vibe_check.db}}"

# If VIBE_CHECK_DB was set, don't consume first argument as DB path
if [ -n "$VIBE_CHECK_DB" ]; then
    QUERY_ARGS=("$@")
else
    QUERY_ARGS=("${@:2}")
fi

if [ ! -f "$DB_PATH" ]; then
    echo "Error: Database not found at $DB_PATH"
    exit 1
fi

# Use read-only mode to avoid database locks
sqlite3 "file:${DB_PATH}?mode=ro" "${QUERY_ARGS[@]}"
