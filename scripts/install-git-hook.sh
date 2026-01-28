#!/bin/bash
#
# Install the vibe-check git hooks into a repository
#
# Installs:
#   - prepare-commit-msg: Adds session links to commit messages
#   - post-commit: Attaches full transcripts as git notes
#
# Usage:
#   install-git-hook.sh [repo-path]
#
# If no path given, installs in current directory.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Target directory
REPO_DIR="${1:-.}"
HOOK_DIR="$REPO_DIR/.git/hooks"

if [ ! -d "$HOOK_DIR" ]; then
    echo "Error: $REPO_DIR is not a git repository (no .git/hooks found)"
    exit 1
fi

install_hook() {
    local hook_name="$1"
    local description="$2"
    local source="$SCRIPT_DIR/$hook_name"
    local target="$HOOK_DIR/$hook_name"

    if [ ! -f "$source" ]; then
        echo "Warning: $hook_name not found at $source, skipping"
        return
    fi

    if [ -f "$target" ] && [ ! -L "$target" ]; then
        echo "Warning: $hook_name hook already exists at $target"
        read -p "Overwrite? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "  Skipped $hook_name"
            return
        fi
    fi

    ln -sf "$source" "$target"
    chmod +x "$target"
    echo "✓ Installed $hook_name: $description"
}

install_hook "prepare-commit-msg" "Adds session links to commit messages"
install_hook "post-commit" "Attaches full transcripts as git notes"

echo ""
echo "Done. To disable notes, set VIBE_CHECK_NOTES=0"
