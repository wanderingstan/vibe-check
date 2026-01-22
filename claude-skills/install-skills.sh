#!/bin/bash
# Install Claude Code skills for vibe-check usage analysis
#
# This script installs vibe-check Claude Code skills to your ~/.claude/skills directory.
# Skills are already in the correct directory structure: skill-name/SKILL.md
#
# Claude Code requires skills to be in this format for auto-discovery.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$HOME/.claude/skills"
BACKUP_DIR="$HOME/.claude/skills-backup-$(date +%Y%m%d-%H%M%S)"

echo "🔧 Installing Claude Code skills for vibe-check..."
echo ""

# Create skills directory if it doesn't exist
if [ ! -d "$SKILLS_DIR" ]; then
    echo "Creating ~/.claude/skills directory..."
    mkdir -p "$SKILLS_DIR"
fi

# Find all skill directories (directories containing SKILL.md)
INSTALLED=0
NEEDS_BACKUP=false

for skill_dir in "$SCRIPT_DIR"/*/; do
    skill_name=$(basename "$skill_dir")

    # Skip if not a directory or no SKILL.md inside
    if [ ! -d "$skill_dir" ] || [ ! -f "$skill_dir/SKILL.md" ]; then
        continue
    fi

    # Check if backup needed
    if [ -f "$SKILLS_DIR/${skill_name}.md" ] || [ -d "$SKILLS_DIR/${skill_name}" ]; then
        NEEDS_BACKUP=true
    fi
done

if [ "$NEEDS_BACKUP" = true ]; then
    echo "⚠️  Some skills already exist. Creating backup..."
    mkdir -p "$BACKUP_DIR"
fi

# Install each skill
echo "Installing skills..."
for skill_dir in "$SCRIPT_DIR"/*/; do
    skill_name=$(basename "$skill_dir")

    # Skip if not a directory or no SKILL.md inside
    if [ ! -d "$skill_dir" ] || [ ! -f "$skill_dir/SKILL.md" ]; then
        continue
    fi

    dest_dir="$SKILLS_DIR/$skill_name"

    # Backup old flat format if present
    if [ -f "$SKILLS_DIR/${skill_name}.md" ]; then
        mv "$SKILLS_DIR/${skill_name}.md" "$BACKUP_DIR/"
        echo "  Backed up & removed: ${skill_name}.md (old flat format)"
    fi

    # Backup existing directory if present
    if [ -d "$dest_dir" ]; then
        cp -r "$dest_dir" "$BACKUP_DIR/"
        rm -rf "$dest_dir"
        echo "  Backed up & removed: ${skill_name}/ (existing)"
    fi

    # Copy skill directory
    cp -r "$skill_dir" "$dest_dir"
    echo "  ✓ ${skill_name}/SKILL.md"
    INSTALLED=$((INSTALLED + 1))
done

if [ "$NEEDS_BACKUP" = true ]; then
    echo ""
    echo "  Backup location: $BACKUP_DIR"
fi

echo ""
echo "✓ Installed $INSTALLED skills to ~/.claude/skills/"
echo ""
echo "📁 Directory structure:"
echo "  ~/.claude/skills/"
for skill_dir in "$SCRIPT_DIR"/*/; do
    skill_name=$(basename "$skill_dir")
    if [ -f "$skill_dir/SKILL.md" ]; then
        echo "    └── ${skill_name}/SKILL.md"
    fi
done
echo ""
echo "📚 Available skills:"
echo "  • claude-stats - Usage statistics"
echo "  • search-conversations - Search conversation history"
echo "  • analyze-tools - Tool usage analysis"
echo "  • recent-work - Recent sessions and activity"
echo "  • view-stats - Open stats page in browser"
echo "  • get-session-id - Get current session ID and log file"
echo "  • share-session - Create public share link for current session"
echo ""
echo "🎯 Try them out!"
echo "  Just ask Claude:"
echo "    'claude stats'"
echo "    'what have I been working on today?'"
echo "    'search my conversations for X'"
echo "    'what tools do I use most?'"
echo "    'vibe stats' or 'open stats'"
echo "    'get session id' or 'what session is this?'"
echo "    'share session' or 'create share link'"
echo ""
echo "⚠️  Note: You may need to restart Claude Code for skills to be discovered."
echo ""
echo "✅ Installation complete!"
