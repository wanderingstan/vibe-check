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
echo "║   🧜 Vibe Check Uninstaller           ║"
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
echo -e "  - Homebrew package (if installed via brew)"
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

# Stop Homebrew service if running
if command -v brew &> /dev/null && brew services list 2>/dev/null | grep -q "vibe-check.*started"; then
    echo -e "${BLUE}Stopping Homebrew service...${NC}"
    brew services stop vibe-check 2>/dev/null || true
    echo -e "${GREEN}✓ Homebrew service stopped${NC}"
fi

# Uninstall Homebrew package if installed
if command -v brew &> /dev/null && brew list vibe-check &> /dev/null; then
    echo -e "${BLUE}Uninstalling Homebrew package...${NC}"
    brew uninstall vibe-check 2>/dev/null || true
    echo -e "${GREEN}✓ Homebrew package uninstalled${NC}"
fi

# Stop any running monitor processes
echo -e "${BLUE}Checking for running monitor processes...${NC}"
MONITOR_PIDS=$(pgrep -f "vibe-check.py" || true)
if [ ! -z "$MONITOR_PIDS" ]; then
    echo -e "${YELLOW}Stopping monitor processes: $MONITOR_PIDS${NC}"
    kill $MONITOR_PIDS 2>/dev/null || true
    sleep 1
    echo -e "${GREEN}✓ Monitor processes stopped${NC}"
else
    echo -e "${GREEN}✓ No running monitor processes found${NC}"
fi

# Stop and remove systemd service (Linux)
if [ -f "$HOME/.config/systemd/user/vibe-check.service" ]; then
    echo -e "${BLUE}Removing systemd service...${NC}"
    systemctl --user stop vibe-check 2>/dev/null || true
    systemctl --user disable vibe-check 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/vibe-check.service"
    systemctl --user daemon-reload 2>/dev/null || true
    echo -e "${GREEN}✓ Systemd service removed${NC}"
fi

# Stop and remove launchd service (macOS)
if [ -f "$HOME/Library/LaunchAgents/com.vibecheck.monitor.plist" ]; then
    echo -e "${BLUE}Removing LaunchAgent...${NC}"
    launchctl unload "$HOME/Library/LaunchAgents/com.vibecheck.monitor.plist" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.vibecheck.monitor.plist"
    echo -e "${GREEN}✓ LaunchAgent removed${NC}"
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
