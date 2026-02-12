#!/bin/bash
#
# Remote Test Runner for Vibe Check
#
# This script is designed to be run via curl on a fresh Mac to test
# the complete installation process end-to-end.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wanderingstan/vibe-check/main/tests/remote-test.sh | bash
#
# Or for local testing:
#   ssh user@mac-mini 'bash -s' < ./tests/remote-test.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Vibe Check Remote Installation Test                ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

# Check prerequisites
echo -e "${BOLD}Checking prerequisites...${NC}"

if ! command -v python3 &> /dev/null; then
    echo -e "${RED}✗ Python 3 not found${NC}"
    echo "Install Python 3 first: https://www.python.org/downloads/"
    exit 2
fi
echo -e "${GREEN}✓ Python 3 found${NC}"

if ! command -v git &> /dev/null; then
    echo -e "${RED}✗ Git not found${NC}"
    echo "Install git: brew install git (macOS) or use your package manager"
    exit 2
fi
echo -e "${GREEN}✓ Git found${NC}"

if [ ! -d "$HOME/.claude/projects" ]; then
    echo -e "${YELLOW}⚠ Claude Code not found${NC}"
    echo "Creating mock ~/.claude/projects for testing..."
    mkdir -p "$HOME/.claude/projects"
    echo -e "${GREEN}✓ Mock Claude Code directory created${NC}"
    echo ""
    echo "Note: This is a mock directory for testing the installer."
    echo "For real usage, install Claude Code:"
    echo "  https://code.claude.com/docs/en/quickstart"
    echo ""
else
    echo -e "${GREEN}✓ Claude Code detected${NC}"
fi

# Create temp directory for test
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"

echo ""
echo -e "${BOLD}Cloning vibe-check repository...${NC}"
if ! git clone https://github.com/wanderingstan/vibe-check.git --quiet; then
    echo -e "${RED}✗ Failed to clone repository${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Repository cloned${NC}"

cd vibe-check

echo ""
echo -e "${BOLD}Running automated test suite...${NC}"
if ! ./tests/test-install.sh --quick; then
    echo ""
    echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
    echo -e "${RED}Tests failed! Check output above for details.${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}All tests passed successfully!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""

# Cleanup
echo -e "${BLUE}Cleaning up test directory...${NC}"
cd "$HOME"
rm -rf "$TEST_DIR"

echo ""
echo -e "${BOLD}Installation verified on this system!${NC}"
echo ""
echo "Your vibe-check installation is now active."
echo ""
echo "Useful commands:"
echo "  vibe-check status      # Check if monitoring is running"
echo "  vibe-check logs        # View logs"
echo "  vibe-check auth login  # Set up remote sync (optional)"
echo ""
