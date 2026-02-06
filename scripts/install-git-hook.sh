#!/bin/bash
#
# Install the vibe-check git hooks into a repository or globally
#
# Installs:
#   - prepare-commit-msg: Adds session links to commit messages
#   - post-commit: Attaches full transcripts as git notes
#
# Usage:
#   install-git-hook.sh [--global] [--no-notes] [repo-path]
#
# Options:
#   --global     Install hooks globally (all repos)
#   --no-notes   Skip git notes hook (only install commit messages)
#   repo-path    Install to specific repository (default: current directory)
#
# Examples:
#   install-git-hook.sh                    # Install to current repo
#   install-git-hook.sh --global           # Install globally
#   install-git-hook.sh --no-notes         # Install without git notes
#   install-git-hook.sh /path/to/repo      # Install to specific repo
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
INSTALL_GLOBAL=false
SKIP_NOTES=false
REPO_DIR="."

while [[ $# -gt 0 ]]; do
    case $1 in
        --global)
            INSTALL_GLOBAL=true
            shift
            ;;
        --no-notes)
            SKIP_NOTES=true
            shift
            ;;
        *)
            REPO_DIR="$1"
            shift
            ;;
    esac
done

# Function to install hook with chaining support
install_hook_with_chaining() {
    local source_hook="$1"
    local target_hook="$2"
    local hook_name="$3"
    local description="$4"

    if [ ! -f "$source_hook" ]; then
        echo -e "${YELLOW}Warning: $hook_name not found at $source_hook, skipping${NC}"
        return
    fi

    if [ -f "$target_hook" ] && [ ! -L "$target_hook" ]; then
        # Existing hook found - offer to chain
        echo -e "${YELLOW}⚠ $hook_name hook already exists at $target_hook${NC}"
        echo -e "  [c] Chain (keep existing, run vibe-check after) - Recommended"
        echo -e "  [r] Replace (backup old hook)"
        echo -e "  [s] Skip"
        read -p "$(echo -e ${YELLOW}"Choice [c/r/s]: "${NC})" -n 1 -r
        echo

        if [[ $REPLY =~ ^[Cc]$ ]]; then
            # Chain: rename existing to .local, install ours
            mv "$target_hook" "${target_hook}.local"
            chmod +x "${target_hook}.local"
            ln -sf "$source_hook" "$target_hook"
            chmod +x "$target_hook"
            echo -e "${GREEN}✓ Installed $hook_name: $description (chained with existing)${NC}"
        elif [[ $REPLY =~ ^[Rr]$ ]]; then
            # Replace: backup and install ours
            cp "$target_hook" "${target_hook}.backup"
            ln -sf "$source_hook" "$target_hook"
            chmod +x "$target_hook"
            echo -e "${GREEN}✓ Installed $hook_name: $description (old hook backed up)${NC}"
        else
            echo -e "${YELLOW}Skipped $hook_name${NC}"
        fi
    else
        # No existing hook or it's already a symlink
        ln -sf "$source_hook" "$target_hook"
        chmod +x "$target_hook"
        echo -e "${GREEN}✓ Installed $hook_name: $description${NC}"
    fi
}

if [ "$INSTALL_GLOBAL" = true ]; then
    # Install globally
    GLOBAL_HOOKS_DIR="$HOME/.vibe-check/git-hooks"
    mkdir -p "$GLOBAL_HOOKS_DIR"

    echo -e "${BLUE}Installing git hooks globally...${NC}"
    echo ""

    # Install hooks (no chaining needed for global - simpler approach)
    install_hook_with_chaining \
        "$SCRIPT_DIR/prepare-commit-msg" \
        "$GLOBAL_HOOKS_DIR/prepare-commit-msg" \
        "prepare-commit-msg" \
        "commit messages with links to Claude sessions"

    if [ "$SKIP_NOTES" = false ]; then
        install_hook_with_chaining \
            "$SCRIPT_DIR/post-commit" \
            "$GLOBAL_HOOKS_DIR/post-commit" \
            "post-commit" \
            "git notes with full text of Claude sessions"
    else
        echo -e "${YELLOW}Skipped post-commit (git notes disabled with --no-notes)${NC}"
    fi

    # Set global hooks path
    CURRENT_HOOKS_PATH=$(git config --global --get core.hooksPath 2>/dev/null || echo "")
    if [ -n "$CURRENT_HOOKS_PATH" ] && [ "$CURRENT_HOOKS_PATH" != "$GLOBAL_HOOKS_DIR" ]; then
        echo ""
        echo -e "${YELLOW}⚠ Git global core.hooksPath is already set to: $CURRENT_HOOKS_PATH${NC}"
        read -p "$(echo -e ${YELLOW}"Replace with $GLOBAL_HOOKS_DIR? [y/N]: "${NC})" -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            git config --global core.hooksPath "$GLOBAL_HOOKS_DIR"
            echo -e "${GREEN}✓ Updated global hooks path${NC}"
        else
            echo -e "${YELLOW}Skipped setting global hooks path${NC}"
            echo -e "${BLUE}To set manually: git config --global core.hooksPath $GLOBAL_HOOKS_DIR${NC}"
        fi
    else
        git config --global core.hooksPath "$GLOBAL_HOOKS_DIR"
        echo -e "${GREEN}✓ Set global hooks path${NC}"
    fi

    echo ""
    echo -e "${GREEN}Global hooks installed to: $GLOBAL_HOOKS_DIR${NC}"
    echo -e "${BLUE}These hooks will apply to all git repositories${NC}"
    echo ""
    echo -e "${BLUE}To disable git notes: export VIBE_CHECK_NOTES=0${NC}"
else
    # Install to specific repo
    HOOK_DIR="$REPO_DIR/.git/hooks"

    if [ ! -d "$HOOK_DIR" ]; then
        echo -e "${RED}Error: $REPO_DIR is not a git repository (no .git/hooks found)${NC}"
        exit 1
    fi

    echo -e "${BLUE}Installing git hooks to: $REPO_DIR${NC}"
    echo ""

    install_hook_with_chaining \
        "$SCRIPT_DIR/prepare-commit-msg" \
        "$HOOK_DIR/prepare-commit-msg" \
        "prepare-commit-msg" \
        "commit messages with links to Claude sessions"

    if [ "$SKIP_NOTES" = false ]; then
        install_hook_with_chaining \
            "$SCRIPT_DIR/post-commit" \
            "$HOOK_DIR/post-commit" \
            "post-commit" \
            "git notes with full text of Claude sessions"
    else
        echo -e "${YELLOW}Skipped post-commit (git notes disabled with --no-notes)${NC}"
    fi

    echo ""
    echo -e "${GREEN}Hooks installed to: $HOOK_DIR${NC}"
    echo ""
    echo -e "${BLUE}To disable git notes: export VIBE_CHECK_NOTES=0${NC}"
fi
