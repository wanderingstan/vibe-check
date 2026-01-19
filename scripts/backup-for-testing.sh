#!/bin/bash
# backup-for-testing.sh - Backup vibe-check state for clean install testing
#
# Backs up all vibe-check data, service config, and skills.
# After backup, clears the original locations so you can test a fresh install.
#
# Usage:
#   ./scripts/backup-for-testing.sh                     # Backup to ~/.vibe-check-backup/
#   ./scripts/backup-for-testing.sh /path/to/backup     # Backup to custom directory
#   ./scripts/backup-for-testing.sh -f [backup_dir]     # Force overwrite existing backup

set -e

DATA_DIR="/opt/homebrew/var/vibe-check"
LOG_DIR="/opt/homebrew/var/log"
LAUNCHAGENT="$HOME/Library/LaunchAgents/com.vibecheck.monitor.plist"
SKILLS_DIR="$HOME/.claude/skills"
FORCE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

# Parse args
while getopts "f" opt; do
    case $opt in
        f) FORCE=true ;;
        *) echo "Usage: $0 [-f] [backup_dir]"; exit 1 ;;
    esac
done
shift $((OPTIND-1))

# Set backup directory (positional arg or default)
BACKUP_DIR="${1:-$HOME/.vibe-check-backup}"

echo "=== vibe-check Backup for Testing ==="
echo ""

# Check if backup already exists
if [ -d "$BACKUP_DIR" ]; then
    if [ "$FORCE" = true ]; then
        print_warning "Removing existing backup (force mode)"
        rm -rf "$BACKUP_DIR"
    else
        print_error "Backup already exists at $BACKUP_DIR"
        echo "Use -f to force overwrite, or run restore-from-testing.sh first"
        exit 1
    fi
fi

# Confirm before proceeding
echo "This will:"
echo "  1. Stop the vibe-check service"
echo "  2. Backup data, logs, service config, and skills to $BACKUP_DIR"
echo "  3. Clear the original locations (for clean install testing)"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo ""

# Stop service
echo "Stopping vibe-check service..."
if brew services list | grep -q "vibe-check.*started"; then
    brew services stop vibe-check 2>/dev/null || true
    print_status "Service stopped"
else
    print_warning "Service was not running"
fi

# Create backup directory structure
mkdir -p "$BACKUP_DIR/data"
mkdir -p "$BACKUP_DIR/logs"
mkdir -p "$BACKUP_DIR/service"
mkdir -p "$BACKUP_DIR/skills"

# Backup data directory
if [ -d "$DATA_DIR" ]; then
    cp -r "$DATA_DIR/"* "$BACKUP_DIR/data/" 2>/dev/null || true
    print_status "Backed up data directory"

    # Clear original
    rm -rf "$DATA_DIR"/*
    print_status "Cleared data directory"
else
    print_warning "No data directory found at $DATA_DIR"
fi

# Backup logs
if ls "$LOG_DIR"/vibe-check* 1>/dev/null 2>&1; then
    cp "$LOG_DIR"/vibe-check* "$BACKUP_DIR/logs/" 2>/dev/null || true
    print_status "Backed up log files"

    # Clear original logs
    rm -f "$LOG_DIR"/vibe-check*
    print_status "Cleared log files"
else
    print_warning "No log files found"
fi

# Backup LaunchAgent
if [ -f "$LAUNCHAGENT" ]; then
    cp "$LAUNCHAGENT" "$BACKUP_DIR/service/"
    print_status "Backed up LaunchAgent plist"

    # Unload and remove
    launchctl unload "$LAUNCHAGENT" 2>/dev/null || true
    rm -f "$LAUNCHAGENT"
    print_status "Removed LaunchAgent"
else
    print_warning "No LaunchAgent found at $LAUNCHAGENT"
fi

# Backup vibe-check related skills
if [ -d "$SKILLS_DIR" ]; then
    # Copy vibe-check related skill files (check content for vibe-check references)
    for skill in "$SKILLS_DIR"/*.md; do
        if [ -f "$skill" ] && grep -qi "vibe-check\|vibe_check" "$skill" 2>/dev/null; then
            cp "$skill" "$BACKUP_DIR/skills/"
            skill_name=$(basename "$skill")
            print_status "Backed up skill: $skill_name"
            rm -f "$skill"
        fi
    done

    # Also check for skills installed by our installer (known filenames)
    for known_skill in "vibe.md" "vibe-check.md"; do
        if [ -f "$SKILLS_DIR/$known_skill" ]; then
            if [ ! -f "$BACKUP_DIR/skills/$known_skill" ]; then
                cp "$SKILLS_DIR/$known_skill" "$BACKUP_DIR/skills/"
                print_status "Backed up skill: $known_skill"
            fi
            rm -f "$SKILLS_DIR/$known_skill"
        fi
    done
else
    print_warning "No skills directory found at $SKILLS_DIR"
fi

# Write backup metadata
cat > "$BACKUP_DIR/backup-info.txt" << EOF
vibe-check backup
Created: $(date)
Host: $(hostname)
User: $(whoami)
EOF

echo ""
echo "=== Backup Complete ==="
echo ""
echo "Backup location: $BACKUP_DIR"
echo ""
echo "Contents:"
ls -la "$BACKUP_DIR/" 2>/dev/null || true
echo ""
echo "You can now test a clean install."
if [ "$BACKUP_DIR" = "$HOME/.vibe-check-backup" ]; then
    echo "Run ./scripts/restore-from-testing.sh when done to restore your data."
else
    echo "Run ./scripts/restore-from-testing.sh \"$BACKUP_DIR\" when done to restore your data."
fi
