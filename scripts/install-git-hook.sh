#!/bin/bash
#
# Install the vibe-check git hook into a repository
#
# Usage:
#   install-git-hook.sh [repo-path]
#
# If no path given, installs in current directory.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SOURCE="$SCRIPT_DIR/prepare-commit-msg"

# Target directory
REPO_DIR="${1:-.}"
HOOK_DIR="$REPO_DIR/.git/hooks"

if [ ! -d "$HOOK_DIR" ]; then
    echo "Error: $REPO_DIR is not a git repository (no .git/hooks found)"
    exit 1
fi

if [ ! -f "$HOOK_SOURCE" ]; then
    echo "Error: Hook script not found at $HOOK_SOURCE"
    exit 1
fi

TARGET="$HOOK_DIR/prepare-commit-msg"

# Check for existing hook
if [ -f "$TARGET" ]; then
    echo "Warning: prepare-commit-msg hook already exists at $TARGET"
    read -p "Overwrite? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Symlink the hook (so updates to the script are automatically used)
ln -sf "$HOOK_SOURCE" "$TARGET"
chmod +x "$TARGET"

echo "✓ Installed vibe-check git hook at $TARGET"
echo "  Claude sessions will be appended to commit messages."
