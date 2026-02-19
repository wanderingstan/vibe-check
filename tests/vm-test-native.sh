#!/bin/bash
#
# VM-based Testing for VibeCheck Native macOS App
#
# Tests the native Swift app DMG installation on a clean macOS VM using Tart.
# This validates that the .app bundle installs correctly, skills are set up,
# and the app functions properly on a fresh system.
#
# Prerequisites:
#   brew install cirruslabs/cli/tart
#   Built DMG: dist/VibeCheck-2.0.0.dmg
#
# First-time setup:
#   On first run, macOS will prompt to approve the Tart Guest Agent.
#   Run ./vm-test-native.sh --shell, wait for notification, then exit and re-run.
#   This is a one-time step - subsequent runs work automatically.
#
# Usage:
#   ./vm-test-native.sh                    # Run tests in VM
#   ./vm-test-native.sh --setup            # Set up VM only
#   ./vm-test-native.sh --quick            # Quick tests (cached VM)
#   ./vm-test-native.sh --cleanup          # Remove VM
#   ./vm-test-native.sh --shell            # Open shell in VM
#   ./vm-test-native.sh --os-version 14    # Test specific macOS version (13, 14, 15)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
VM_NAME="vibe-check-native-test"
BASE_IMAGE="ghcr.io/cirruslabs/macos-sonoma-base:latest"  # macOS 14
OS_VERSION=""
QUICK_MODE=false
SETUP_ONLY=false
CLEANUP_ONLY=false
SHELL_ONLY=false
DMG_NAME="VibeCheck-2.0.0.dmg"

# Parse arguments
for arg in "$@"; do
    case $arg in
        --quick) QUICK_MODE=true ;;
        --setup) SETUP_ONLY=true ;;
        --cleanup) CLEANUP_ONLY=true ;;
        --shell) SHELL_ONLY=true ;;
        --os-version)
            shift
            OS_VERSION="$1"
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --setup           Set up VM only, don't run tests"
            echo "  --quick           Run quick tests (use cached VM)"
            echo "  --cleanup         Remove the test VM"
            echo "  --shell           Open a shell in the VM"
            echo "  --os-version N    Test specific macOS version (13, 14, or 15)"
            echo "  --help            Show this help"
            echo ""
            echo "Prerequisites:"
            echo "  brew install cirruslabs/cli/tart"
            echo "  Built DMG at: dist/VibeCheck-2.0.0.dmg"
            exit 0
            ;;
    esac
    shift || true
done

# Set base image based on OS version
if [ -n "$OS_VERSION" ]; then
    case "$OS_VERSION" in
        13)
            BASE_IMAGE="ghcr.io/cirruslabs/macos-ventura-base:latest"
            VM_NAME="vibe-check-native-test-13"
            ;;
        14)
            BASE_IMAGE="ghcr.io/cirruslabs/macos-sonoma-base:latest"
            VM_NAME="vibe-check-native-test-14"
            ;;
        15)
            BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"
            VM_NAME="vibe-check-native-test-15"
            ;;
        *)
            echo -e "${RED}Invalid OS version: $OS_VERSION${NC}"
            echo "Valid options: 13, 14, 15"
            exit 1
            ;;
    esac
fi

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DMG_PATH="$REPO_ROOT/dist/$DMG_NAME"

echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   VibeCheck Native App VM Testing (Tart)             ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if Tart is installed
if ! command -v tart &> /dev/null; then
    echo -e "${RED}✗ Tart not installed${NC}"
    echo ""
    echo "Install Tart with:"
    echo "  brew install cirruslabs/cli/tart"
    echo ""
    echo "Tart is a lightweight macOS VM manager built on Apple's Virtualization.framework."
    echo "See: https://tart.run"
    exit 1
fi
echo -e "${GREEN}✓ Tart installed${NC}"

# Check if DMG exists, build if needed
if [ ! -f "$DMG_PATH" ]; then
    echo -e "${YELLOW}⚠ DMG not found at: $DMG_PATH${NC}"
    echo ""
    echo -e "${BLUE}Building DMG...${NC}"

    cd "$REPO_ROOT"

    # Build .app bundle if needed
    if [ ! -d "dist/VibeCheck.app" ]; then
        echo "Building .app bundle..."
        ./Scripts/build-release.sh
    fi

    # Create DMG
    echo "Creating DMG..."
    ./Scripts/create-dmg.sh

    if [ ! -f "$DMG_PATH" ]; then
        echo -e "${RED}✗ Failed to create DMG${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ DMG created${NC}"
else
    echo -e "${GREEN}✓ DMG exists: $DMG_PATH${NC}"
fi

# Cleanup mode
if [ "$CLEANUP_ONLY" = true ]; then
    echo -e "${BLUE}Cleaning up VM...${NC}"
    if tart list | grep -q "^$VM_NAME "; then
        tart delete "$VM_NAME"
        echo -e "${GREEN}✓ VM deleted${NC}"
    else
        echo -e "${YELLOW}⚠ VM not found${NC}"
    fi
    exit 0
fi

# Check if VM exists, create if needed
if ! tart list | grep -q "^$VM_NAME "; then
    echo -e "${BLUE}Creating VM from base image...${NC}"
    echo "This will download ~25GB on first run (cached for future use)"
    echo "Base image: $BASE_IMAGE"
    echo ""

    # Clone base image
    if ! tart clone "$BASE_IMAGE" "$VM_NAME"; then
        echo -e "${RED}✗ Failed to create VM${NC}"
        echo ""
        echo "If the base image download failed, you can try:"
        echo "  tart pull $BASE_IMAGE"
        exit 1
    fi

    echo -e "${GREEN}✓ VM created${NC}"
else
    echo -e "${GREEN}✓ VM exists${NC}"
fi

# Setup only mode
if [ "$SETUP_ONLY" = true ]; then
    echo ""
    echo -e "${GREEN}VM setup complete!${NC}"
    echo ""
    echo "To run tests: ./vm-test-native.sh"
    echo "To open shell: ./vm-test-native.sh --shell"
    echo "To clean up: ./vm-test-native.sh --cleanup"
    exit 0
fi

# Shell mode
if [ "$SHELL_ONLY" = true ]; then
    echo -e "${BLUE}Starting VM and opening shell...${NC}"
    echo ""
    echo "Shared directory mounted at: /Volumes/My Shared Files/repo"
    echo "DMG location in VM: /Volumes/My Shared Files/repo/dist/$DMG_NAME"
    echo ""
    tart run --dir="repo:$REPO_ROOT" "$VM_NAME"
    exit 0
fi

# Run tests in VM
echo ""
echo -e "${BLUE}Starting VM...${NC}"

# Start VM in background with shared directory
tart run --dir="repo:$REPO_ROOT" "$VM_NAME" &
VM_PID=$!

# Function to run commands in VM
vm_exec() {
    tart exec "$VM_NAME" "$@"
}

# Wait for VM to boot and guest agent to be ready
echo "Waiting for VM to boot and guest agent to start..."
echo "(This usually takes 30-60 seconds)"

MAX_WAIT=120  # 2 minutes
ELAPSED=0
READY=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
    # Try to execute a simple command
    if vm_exec echo "ready" &>/dev/null; then
        READY=true
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))

    # Show progress every 15 seconds
    if [ $((ELAPSED % 15)) -eq 0 ]; then
        echo "  Still waiting... (${ELAPSED}s elapsed)"
    else
        echo -n "."
    fi
done
echo ""

if [ "$READY" = false ]; then
    echo -e "${RED}✗ VM failed to become ready after ${MAX_WAIT}s${NC}"
    echo ""
    echo -e "${YELLOW}Most likely cause:${NC}"
    echo "On first boot, macOS requires approval for the Tart Guest Agent."
    echo ""
    echo -e "${YELLOW}To fix (one-time setup):${NC}"
    echo "  1. Open VM interactively:"
    echo "     ./vm-test-native.sh --shell"
    echo ""
    echo "  2. Wait for notification, then exit (Command+Q)"
    echo ""
    echo "  3. Re-run tests:"
    echo "     ./vm-test-native.sh"
    echo ""
    echo -e "${YELLOW}Alternative:${NC}"
    echo "  • Clean up and retry: ./vm-test-native.sh --cleanup && ./vm-test-native.sh"

    tart stop "$VM_NAME" 2>/dev/null || true
    exit 1
fi

echo -e "${GREEN}✓ VM ready${NC}"

# Install DMG and run tests
echo ""
echo -e "${BLUE}Installing VibeCheck from DMG...${NC}"

# Mount DMG
echo "Mounting DMG..."
vm_exec bash -c "hdiutil attach '/Volumes/My Shared Files/repo/dist/$DMG_NAME' -quiet"
sleep 2

# Copy app to Applications
echo "Installing app to /Applications..."
vm_exec bash -c "cp -R '/Volumes/VibeCheck Installer/VibeCheck.app' /Applications/"

# Unmount DMG
echo "Unmounting DMG..."
vm_exec bash -c "hdiutil detach '/Volumes/VibeCheck Installer' -quiet"

echo -e "${GREEN}✓ VibeCheck installed${NC}"

# Copy test script to VM
echo ""
echo -e "${BLUE}Copying test script to VM...${NC}"
vm_exec bash -c "cp '/Volumes/My Shared Files/repo/tests/test-native-app.sh' /tmp/test-native-app.sh"
vm_exec bash -c "chmod +x /tmp/test-native-app.sh"
echo -e "${GREEN}✓ Test script ready${NC}"

# Run tests
echo ""
echo -e "${BLUE}Running tests in VM...${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

TEST_RESULT=0
vm_exec bash -c "/tmp/test-native-app.sh" || TEST_RESULT=$?

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"

# Stop VM
echo ""
echo -e "${BLUE}Stopping VM...${NC}"
tart stop "$VM_NAME"
wait $VM_PID 2>/dev/null || true
echo -e "${GREEN}✓ VM stopped${NC}"

# Report results
echo ""
if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✓ All tests passed in VM!                          ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "The native VibeCheck app successfully:"
    echo "  • Installed from DMG"
    echo "  • Launched without errors"
    echo "  • Created database and schema"
    echo "  • Installed skills"
    echo "  • Registered MCP server"
    echo "  • Passed code signing verification"
    echo ""
    echo "VM is preserved for future test runs."
    echo "To start fresh: ./vm-test-native.sh --cleanup && ./vm-test-native.sh"
    exit 0
else
    echo -e "${RED}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   ✗ Tests failed in VM                               ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "To debug:"
    echo "  ./vm-test-native.sh --shell   # Open shell in VM"
    echo "  # Then manually run:"
    echo "  #   /tmp/test-native-app.sh"
    echo ""
    echo "To clean up and retry:"
    echo "  ./vm-test-native.sh --cleanup && ./vm-test-native.sh"
    exit 1
fi
