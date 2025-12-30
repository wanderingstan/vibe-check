#!/bin/bash

# Vibe Check Uninstaller

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="$HOME/.vibe-check"

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════╗"
echo "║     Vibe Check Uninstaller            ║"
echo "╚═══════════════════════════════════════╝"
echo -e "${NC}"

# Check if installed
if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}Vibe Check is not installed at $INSTALL_DIR${NC}"
    echo -e "${BLUE}Nothing to uninstall.${NC}"
    exit 0
fi

# Show what will be removed
echo -e "${YELLOW}This will remove:${NC}"
echo -e "  - Installation directory: $INSTALL_DIR"
echo -e "  - All conversation data and state"
echo -e "  - Configuration file (including API key)"
echo ""
echo -e "${YELLOW}Note: This will NOT delete your account on the server.${NC}"
echo -e "${YELLOW}Your API key will remain valid if you reinstall.${NC}"
echo ""

# Confirm
read -p "Are you sure you want to uninstall Vibe Check? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Uninstall cancelled.${NC}"
    exit 0
fi

# Stop any running monitor processes
echo -e "${BLUE}Checking for running monitor processes...${NC}"
MONITOR_PIDS=$(pgrep -f "$INSTALL_DIR/monitor.py" || true)
if [ ! -z "$MONITOR_PIDS" ]; then
    echo -e "${YELLOW}Stopping monitor processes: $MONITOR_PIDS${NC}"
    kill $MONITOR_PIDS 2>/dev/null || true
    sleep 1
    echo -e "${GREEN}✓ Monitor processes stopped${NC}"
else
    echo -e "${GREEN}✓ No running monitor processes found${NC}"
fi

# Remove installation directory
echo -e "${BLUE}Removing installation directory...${NC}"
rm -rf "$INSTALL_DIR"
echo -e "${GREEN}✓ Installation directory removed${NC}"

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Uninstall Complete!                 ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Vibe Check has been removed from your system.${NC}"
echo ""
echo -e "${BLUE}To reinstall later, run:${NC}"
echo -e "  curl -fsSL https://vibecheck.wanderingstan.com/install.sh | bash"
echo ""
