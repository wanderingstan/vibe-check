#!/bin/bash
# Install Claude Code skills for vibe-check usage analysis
#
# This script copies the vibe-check Claude Code skills to your ~/.claude/skills directory
# so Claude can query your local conversation database.

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

# Backup existing skills if any match
NEEDS_BACKUP=false
for skill in claude-stats search-conversations analyze-tools recent-work; do
    if [ -f "$SKILLS_DIR/${skill}.md" ]; then
        NEEDS_BACKUP=true
        break
    fi
done

if [ "$NEEDS_BACKUP" = true ]; then
    echo "⚠️  Some skills already exist. Creating backup..."
    mkdir -p "$BACKUP_DIR"
    for skill in claude-stats search-conversations analyze-tools recent-work; do
        if [ -f "$SKILLS_DIR/${skill}.md" ]; then
            cp "$SKILLS_DIR/${skill}.md" "$BACKUP_DIR/"
            echo "  Backed up: ${skill}.md"
        fi
    done
    echo "  Backup location: $BACKUP_DIR"
    echo ""
fi

# Copy skills
echo "Installing skills..."
cp "$SCRIPT_DIR/claude-stats.md" "$SKILLS_DIR/"
cp "$SCRIPT_DIR/search-conversations.md" "$SKILLS_DIR/"
cp "$SCRIPT_DIR/analyze-tools.md" "$SKILLS_DIR/"
cp "$SCRIPT_DIR/recent-work.md" "$SKILLS_DIR/"

echo "✓ Installed 4 skills to ~/.claude/skills/"
echo ""
echo "📚 Available skills:"
echo "  • claude-stats.md - Usage statistics"
echo "  • search-conversations.md - Search conversation history"
echo "  • analyze-tools.md - Tool usage analysis"
echo "  • recent-work.md - Recent sessions and activity"
echo ""
echo "🎯 Try them out!"
echo "  Just ask Claude:"
echo "    'claude stats'"
echo "    'what have I been working on today?'"
echo "    'search my conversations for X'"
echo "    'what tools do I use most?'"
echo ""
echo "📖 For more info, see:"
echo "  - SKILLS-README.md - Detailed documentation"
echo "  - SKILLS-SUMMARY.md - Quick reference"
echo ""
echo "✅ Installation complete!"
