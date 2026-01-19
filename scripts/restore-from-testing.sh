#!/bin/bash
# restore-from-testing.sh - Restore vibe-check state from backup
#
# Restores all vibe-check data, service config, and skills from backup.
# Run this after testing a clean install to get back to your original state.
#
# Usage:
#   ./scripts/restore-from-testing.sh                     # Restore from ~/.vibe-check-backup/
#   ./scripts/restore-from-testing.sh /path/to/backup     # Restore from custom directory
#   ./scripts/restore-from-testing.sh -k [backup_dir]     # Keep backup after restore
#   ./scripts/restore-from-testing.sh --no-merge          # Skip merging test events into backup

set -e

DATA_DIR="/opt/homebrew/var/vibe-check"
LOG_DIR="/opt/homebrew/var/log"
LAUNCHAGENT_DIR="$HOME/Library/LaunchAgents"
SKILLS_DIR="$HOME/.claude/skills"
KEEP_BACKUP=false
MERGE_EVENTS=true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

# Parse args (handle long options first)
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-merge)
            MERGE_EVENTS=false
            shift
            ;;
        -k)
            KEEP_BACKUP=true
            shift
            ;;
        -*)
            echo "Usage: $0 [-k] [--no-merge] [backup_dir]"
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}"

# Set backup directory (positional arg or default)
BACKUP_DIR="${1:-$HOME/.vibe-check-backup}"

echo "=== vibe-check Restore from Testing ==="
echo ""

# Check if backup exists
if [ ! -d "$BACKUP_DIR" ]; then
    print_error "No backup found at $BACKUP_DIR"
    echo "Run backup-for-testing.sh first to create a backup."
    exit 1
fi

# Validate backup
if [ ! -f "$BACKUP_DIR/backup-info.txt" ]; then
    print_error "Invalid backup: missing backup-info.txt"
    exit 1
fi

echo "Backup info:"
cat "$BACKUP_DIR/backup-info.txt"
echo ""

# Confirm before proceeding
echo "This will:"
echo "  1. Stop any running vibe-check service"
if [ "$MERGE_EVENTS" = true ]; then
    echo "  2. Merge conversation_events from current DB into backup"
    echo "  3. Restore data, logs, service config, and skills from backup"
    echo "  4. Start the vibe-check service"
    if [ "$KEEP_BACKUP" = false ]; then
        echo "  5. Remove the backup directory"
    fi
else
    echo "  2. Restore data, logs, service config, and skills from backup"
    echo "  3. Start the vibe-check service"
    if [ "$KEEP_BACKUP" = false ]; then
        echo "  4. Remove the backup directory"
    fi
fi
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo ""

# Stop any running service first (check both PID-based and brew services)
echo "Stopping any running vibe-check service..."

# First check for PID-based process (started via 'vibe-check start')
PID_FILE="$DATA_DIR/.monitor.pid"
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "  Stopping PID-based process ($PID)..."
        kill -TERM "$PID" 2>/dev/null || true
        # Wait up to 5 seconds for graceful shutdown
        for i in $(seq 1 50); do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        # Force kill if still running
        if kill -0 "$PID" 2>/dev/null; then
            kill -9 "$PID" 2>/dev/null || true
            sleep 0.5
        fi
        rm -f "$PID_FILE"
        print_status "PID-based process stopped"
    else
        rm -f "$PID_FILE"  # Clean up stale PID file
    fi
fi

# Also check for brew services managed process
brew services stop vibe-check 2>/dev/null || true
launchctl unload "$LAUNCHAGENT_DIR/com.vibecheck.monitor.plist" 2>/dev/null || true

# Verify nothing is still running
if pgrep -f "vibe-check.py" >/dev/null 2>&1; then
    print_warning "vibe-check process still detected, attempting to stop..."
    pkill -f "vibe-check.py" 2>/dev/null || true
    sleep 1
fi

# Merge conversation_events from current (testing) DB into backup before restoring
CURRENT_DB="$DATA_DIR/vibe_check.db"
BACKUP_DB="$BACKUP_DIR/data/vibe_check.db"

if [ "$MERGE_EVENTS" = true ] && [ -f "$CURRENT_DB" ] && [ -f "$BACKUP_DB" ]; then
    echo "Merging conversation_events from testing database..."

    # Count events in current DB before merge
    CURRENT_COUNT=$(sqlite3 "$CURRENT_DB" "SELECT COUNT(*) FROM conversation_events;" 2>/dev/null || echo "0")
    BACKUP_COUNT_BEFORE=$(sqlite3 "$BACKUP_DB" "SELECT COUNT(*) FROM conversation_events;" 2>/dev/null || echo "0")

    # Merge: insert events from current DB into backup DB, skipping duplicates by event_uuid
    sqlite3 "$BACKUP_DB" <<EOF
ATTACH DATABASE '$CURRENT_DB' AS current_db;

INSERT OR IGNORE INTO conversation_events (
    file_name, line_number, event_data, user_name, inserted_at
)
SELECT
    file_name, line_number, event_data, user_name, inserted_at
FROM current_db.conversation_events
WHERE event_uuid NOT IN (SELECT event_uuid FROM conversation_events WHERE event_uuid IS NOT NULL)
   OR event_uuid IS NULL;

DETACH DATABASE current_db;
EOF

    BACKUP_COUNT_AFTER=$(sqlite3 "$BACKUP_DB" "SELECT COUNT(*) FROM conversation_events;" 2>/dev/null || echo "0")
    MERGED_COUNT=$((BACKUP_COUNT_AFTER - BACKUP_COUNT_BEFORE))

    if [ "$MERGED_COUNT" -gt 0 ]; then
        print_status "Merged $MERGED_COUNT events from testing database (had $CURRENT_COUNT events)"
    else
        print_status "No new events to merge (testing DB had $CURRENT_COUNT events, all duplicates)"
    fi
elif [ "$MERGE_EVENTS" = true ]; then
    if [ ! -f "$CURRENT_DB" ]; then
        print_warning "No current database to merge from"
    elif [ ! -f "$BACKUP_DB" ]; then
        print_warning "No backup database to merge into"
    fi
elif [ "$MERGE_EVENTS" = false ]; then
    print_status "Skipping event merge (--no-merge specified)"
fi

# Restore data directory
if [ -d "$BACKUP_DIR/data" ] && [ "$(ls -A "$BACKUP_DIR/data" 2>/dev/null)" ]; then
    mkdir -p "$DATA_DIR"
    cp -r "$BACKUP_DIR/data/"* "$DATA_DIR/" 2>/dev/null || true
    print_status "Restored data directory"
else
    print_warning "No data to restore"
fi

# Restore logs
if [ -d "$BACKUP_DIR/logs" ] && [ "$(ls -A "$BACKUP_DIR/logs" 2>/dev/null)" ]; then
    cp "$BACKUP_DIR/logs/"* "$LOG_DIR/" 2>/dev/null || true
    print_status "Restored log files"
else
    print_warning "No logs to restore"
fi

# Restore LaunchAgent
if [ -d "$BACKUP_DIR/service" ] && [ "$(ls -A "$BACKUP_DIR/service" 2>/dev/null)" ]; then
    mkdir -p "$LAUNCHAGENT_DIR"
    cp "$BACKUP_DIR/service/"* "$LAUNCHAGENT_DIR/" 2>/dev/null || true
    print_status "Restored LaunchAgent plist"
else
    print_warning "No LaunchAgent to restore"
fi

# Restore skills
if [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A "$BACKUP_DIR/skills" 2>/dev/null)" ]; then
    mkdir -p "$SKILLS_DIR"
    cp "$BACKUP_DIR/skills/"* "$SKILLS_DIR/" 2>/dev/null || true
    print_status "Restored skills"
else
    print_warning "No skills to restore"
fi

# Start service
echo ""
echo "Starting vibe-check service..."
if brew services list | grep -q "vibe-check"; then
    brew services start vibe-check 2>/dev/null || true
    print_status "Service started via Homebrew"
elif [ -f "$LAUNCHAGENT_DIR/com.vibecheck.monitor.plist" ]; then
    launchctl load "$LAUNCHAGENT_DIR/com.vibecheck.monitor.plist" 2>/dev/null || true
    print_status "Service started via LaunchAgent"
else
    print_warning "No service configuration found - you may need to reinstall"
fi

# Clean up backup
if [ "$KEEP_BACKUP" = false ]; then
    rm -rf "$BACKUP_DIR"
    print_status "Removed backup directory"
else
    print_warning "Keeping backup at $BACKUP_DIR (use -k flag specified)"
fi

echo ""
echo "=== Restore Complete ==="
echo ""
echo "Your vibe-check installation has been restored."
echo "Run 'vibe-check status' to verify."
