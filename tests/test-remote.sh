#!/bin/bash
#
# Remote Test Helper
#
# Convenience script to run installation tests on a remote Mac via SSH.
#
# Usage:
#   ./test-remote.sh user@mac-mini
#   ./test-remote.sh --quick user@mac-mini
#   ./test-remote.sh --mock-claude user@mac-mini
#   ./test-remote.sh --help

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

QUICK_MODE=""
MOCK_CLAUDE=false
SSH_TARGET=""

# Parse arguments
for arg in "$@"; do
    case $arg in
        --quick)
            QUICK_MODE="--quick"
            ;;
        --mock-claude)
            MOCK_CLAUDE=true
            ;;
        --help)
            echo "Usage: $0 [--quick] [--mock-claude] user@hostname"
            echo ""
            echo "Options:"
            echo "  --quick       Run quick tests only (skip time-consuming tests)"
            echo "  --mock-claude Create mock ~/.claude/projects if it doesn't exist"
            echo ""
            echo "Examples:"
            echo "  $0 user@mac-mini                    # Full test suite"
            echo "  $0 --quick user@192.168.1.10        # Quick tests only"
            echo "  $0 --mock-claude testuser@mac-mini  # Create mock Claude Code dir"
            exit 0
            ;;
        *)
            SSH_TARGET="$arg"
            ;;
    esac
done

if [ -z "$SSH_TARGET" ]; then
    echo -e "${RED}Error: SSH target required${NC}"
    echo "Usage: $0 [--quick] user@hostname"
    exit 1
fi

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Remote Installation Test                           ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Target: $SSH_TARGET"
echo "Mode:   $([ -n "$QUICK_MODE" ] && echo "Quick" || echo "Full")"
echo ""

# Test SSH connection
echo -e "${BLUE}Testing SSH connection...${NC}"
if ! ssh -o ConnectTimeout=5 "$SSH_TARGET" "echo 'Connection successful'" &>/dev/null; then
    echo -e "${RED}✗ Cannot connect to $SSH_TARGET${NC}"
    echo ""
    echo "Make sure:"
    echo "  1. The Mac is powered on and connected to network"
    echo "  2. Remote Login is enabled (System Settings > Sharing)"
    echo "  3. SSH key authentication is set up"
    exit 1
fi
echo -e "${GREEN}✓ SSH connection verified${NC}"

# Check remote prerequisites
echo -e "${BLUE}Checking remote system...${NC}"

# Check Python
if ! ssh "$SSH_TARGET" "command -v python3" &>/dev/null; then
    echo -e "${RED}✗ Python 3 not installed on remote system${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Python 3 available${NC}"

# Check Git
if ! ssh "$SSH_TARGET" "command -v git" &>/dev/null; then
    echo -e "${RED}✗ Git not installed on remote system${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Git available${NC}"

# Check Claude Code
if ! ssh "$SSH_TARGET" "[ -d ~/.claude/projects ]"; then
    if [ "$MOCK_CLAUDE" = true ]; then
        echo -e "${YELLOW}⚠ Claude Code not found, creating mock directory...${NC}"
        ssh "$SSH_TARGET" "mkdir -p ~/.claude/projects"
        echo -e "${GREEN}✓ Mock Claude Code directory created${NC}"
    else
        echo -e "${RED}✗ Claude Code not installed on remote system${NC}"
        echo ""
        echo "Options:"
        echo "  1. Install Claude Code: https://code.claude.com/docs/en/quickstart"
        echo "  2. Use --mock-claude flag to create a mock directory for testing"
        echo ""
        echo "Example: $0 --mock-claude $SSH_TARGET"
        exit 1
    fi
else
    echo -e "${GREEN}✓ Claude Code detected${NC}"
fi

# Create remote temp directory and copy test files
echo ""
echo -e "${BLUE}Preparing remote environment...${NC}"

REMOTE_DIR=$(ssh "$SSH_TARGET" "mktemp -d")
echo "Remote test directory: $REMOTE_DIR"

# Copy repository to remote
echo "Copying repository..."
if ! rsync -az --delete "$REPO_ROOT/" "$SSH_TARGET:$REMOTE_DIR/" \
    --exclude '.git' \
    --exclude 'venv' \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude '.DS_Store'; then
    echo -e "${RED}✗ Failed to copy files to remote${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Repository copied${NC}"

# Run tests remotely
echo ""
echo -e "${BLUE}Running tests on remote system...${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

TEST_RESULT=0
ssh -t "$SSH_TARGET" "cd $REMOTE_DIR && ./tests/test-install.sh $QUICK_MODE --verbose" || TEST_RESULT=$?

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"

# Cleanup remote directory
echo ""
echo -e "${BLUE}Cleaning up remote environment...${NC}"
ssh "$SSH_TARGET" "rm -rf $REMOTE_DIR"
echo -e "${GREEN}✓ Cleanup complete${NC}"

# Report results
echo ""
if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✓ All tests passed on remote system!               ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   ✗ Tests failed on remote system                    ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Check the output above for details."
    exit 1
fi
