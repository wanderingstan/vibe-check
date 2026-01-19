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

set -e

DATA_DIR="/opt/homebrew/var/vibe-check"
LOG_DIR="/opt/homebrew/var/log"
LAUNCHAGENT_DIR="$HOME/Library/LaunchAgents"
SKILLS_DIR="$HOME/.claude/skills"
KEEP_BACKUP=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

# Parse args
while getopts "k" opt; do
    case $opt in
        k) KEEP_BACKUP=true ;;
        *) echo "Usage: $0 [-k] [backup_dir]"; exit 1 ;;
    esac
done
shift $((OPTIND-1))

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
echo "  2. Restore data, logs, service config, and skills from backup"
echo "  3. Start the vibe-check service"
if [ "$KEEP_BACKUP" = false ]; then
    echo "  4. Remove the backup directory"
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
