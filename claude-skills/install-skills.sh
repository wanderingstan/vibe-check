#!/bin/bash
# Install Claude Code skills for vibe-check usage analysis
#
# This script installs vibe-check Claude Code skills to your ~/.claude/skills directory
# using the correct directory structure: skill-name/SKILL.md
#
# Claude Code requires skills to be in this format for auto-discovery.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$HOME/.claude/skills"
BACKUP_DIR="$HOME/.claude/skills-backup-$(date +%Y%m%d-%H%M%S)"

SKILLS="claude-stats search-conversations analyze-tools recent-work view-stats get-session-id share-session"

echo "🔧 Installing Claude Code skills for vibe-check..."
echo ""

# Create skills directory if it doesn't exist
if [ ! -d "$SKILLS_DIR" ]; then
    echo "Creating ~/.claude/skills directory..."
    mkdir -p "$SKILLS_DIR"
fi

# Backup existing skills if any match (check both old flat format and new directory format)
NEEDS_BACKUP=false
for skill in $SKILLS; do
    if [ -f "$SKILLS_DIR/${skill}.md" ] || [ -d "$SKILLS_DIR/${skill}" ]; then
        NEEDS_BACKUP=true
        break
    fi
done

if [ "$NEEDS_BACKUP" = true ]; then
    echo "⚠️  Some skills already exist. Creating backup..."
    mkdir -p "$BACKUP_DIR"
    for skill in $SKILLS; do
        # Backup old flat format
        if [ -f "$SKILLS_DIR/${skill}.md" ]; then
            cp "$SKILLS_DIR/${skill}.md" "$BACKUP_DIR/"
            rm "$SKILLS_DIR/${skill}.md"
            echo "  Backed up & removed: ${skill}.md (old flat format)"
        fi
        # Backup new directory format
        if [ -d "$SKILLS_DIR/${skill}" ]; then
            cp -r "$SKILLS_DIR/${skill}" "$BACKUP_DIR/"
            rm -rf "$SKILLS_DIR/${skill}"
            echo "  Backed up & removed: ${skill}/ (directory)"
        fi
    done
    echo "  Backup location: $BACKUP_DIR"
    echo ""
fi

# Install skills with correct directory structure
echo "Installing skills..."
for skill in $SKILLS; do
    mkdir -p "$SKILLS_DIR/${skill}"
    cp "$SCRIPT_DIR/${skill}.md" "$SKILLS_DIR/${skill}/SKILL.md"
    echo "  ✓ ${skill}/SKILL.md"
done

echo ""
echo "✓ Installed 7 skills to ~/.claude/skills/"
echo ""
echo "📁 Directory structure:"
echo "  ~/.claude/skills/"
for skill in $SKILLS; do
    echo "    └── ${skill}/SKILL.md"
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
