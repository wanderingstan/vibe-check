#!/bin/bash
#
# VM-based Testing with Tart (macOS Virtualization)
#
# Uses Tart (https://tart.run) to create a clean macOS VM for testing.
# This provides a true fresh install environment without needing separate hardware.
#
# Prerequisites:
#   brew install cirruslabs/cli/tart
#
# First-time setup:
#   On first run, macOS will prompt to approve the Tart Guest Agent.
#   Run ./vm-test.sh --shell, wait for notification, then exit and re-run.
#   This is a one-time step - subsequent runs work automatically.
#
# Usage:
#   ./vm-test.sh                    # Run tests in VM
#   ./vm-test.sh --setup            # Set up VM only
#   ./vm-test.sh --quick            # Quick tests
#   ./vm-test.sh --cleanup          # Remove VM
#   ./vm-test.sh --shell            # Open shell in VM (for first-time setup)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
VM_NAME="vibe-check-test"
BASE_IMAGE="ghcr.io/cirruslabs/macos-sonoma-base:latest"
QUICK_MODE=false
SETUP_ONLY=false
CLEANUP_ONLY=false
SHELL_ONLY=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --quick) QUICK_MODE=true ;;
        --setup) SETUP_ONLY=true ;;
        --cleanup) CLEANUP_ONLY=true ;;
        --shell) SHELL_ONLY=true ;;
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --setup    Set up VM only, don't run tests"
            echo "  --quick    Run quick tests only"
            echo "  --cleanup  Remove the test VM"
            echo "  --shell    Open a shell in the VM"
            echo "  --help     Show this help"
            echo ""
            echo "Prerequisites:"
            echo "  brew install cirruslabs/cli/tart"
            exit 0
            ;;
    esac
done

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Vibe Check VM Testing (Tart)                       ║${NC}"
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
    echo "To run tests: ./vm-test.sh"
    echo "To open shell: ./vm-test.sh --shell"
    echo "To clean up: ./vm-test.sh --cleanup"
    exit 0
fi

# Shell mode
if [ "$SHELL_ONLY" = true ]; then
    echo -e "${BLUE}Starting VM and opening shell...${NC}"
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
    echo -e "${YELLOW}Diagnostics:${NC}"

    # Check VM IP address
    echo -n "VM IP address: "
    tart ip "$VM_NAME" 2>/dev/null || echo "not assigned"

    # Check if VM is actually running
    echo -n "VM process: "
    if ps aux | grep -q "[t]art run $VM_NAME"; then
        echo "running"
    else
        echo "not found"
    fi

    echo ""
    echo -e "${YELLOW}Most likely cause:${NC}"
    echo "On first boot, macOS requires approval for the Tart Guest Agent"
    echo "to run in the background. This is a one-time setup step."
    echo ""
    echo -e "${YELLOW}To fix (one-time setup):${NC}"
    echo "  1. Open VM interactively:"
    echo "     ./vm-test.sh --shell"
    echo ""
    echo "  2. In the VM, you'll see a notification:"
    echo "     \"Background Items Added - tart-guest-agent\""
    echo "     Click 'Open Login Items Settings' or ignore the notification"
    echo ""
    echo "  3. The guest agent will be automatically allowed after first boot"
    echo "     (No need to manually enable it in System Settings)"
    echo ""
    echo "  4. Exit the VM (Command+Q) and re-run tests:"
    echo "     ./vm-test.sh"
    echo ""
    echo -e "${YELLOW}Alternative troubleshooting:${NC}"
    echo "  • Clean up and retry: ./vm-test.sh --cleanup && ./vm-test.sh"
    echo "  • Check Tart version: tart --version (visit https://tart.run)"

    tart stop "$VM_NAME" 2>/dev/null || true
    exit 1
fi

echo -e "${GREEN}✓ VM ready${NC}"

# Set up VM environment
echo ""
echo -e "${BLUE}Setting up VM environment...${NC}"

# Install Homebrew (if not already installed)
if ! vm_exec which brew &>/dev/null; then
    echo "Installing Homebrew..."
    vm_exec /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
echo -e "${GREEN}✓ Homebrew installed${NC}"

# Install dependencies
echo "Installing dependencies..."
vm_exec brew install python git
echo -e "${GREEN}✓ Dependencies installed${NC}"

# Install Claude Code (mock installation for testing)
echo "Setting up mock Claude Code directory..."
vm_exec mkdir -p '$HOME/.claude/projects'
echo -e "${GREEN}✓ Mock Claude Code directory created${NC}"

# Copy repository to VM from shared directory
echo ""
echo -e "${BLUE}Copying repository to VM...${NC}"

# Copy from shared directory, excluding unnecessary files
# Shared directory appears at /Volumes/My Shared Files/repo in the VM
vm_exec bash -c "
    mkdir -p /tmp/vibe-check
    cd '/Volumes/My Shared Files/repo'
    rsync -a --exclude='.git' --exclude='venv' --exclude='__pycache__' --exclude='*.pyc' --exclude='.DS_Store' ./ /tmp/vibe-check/
"

# Ensure scripts are executable
vm_exec bash -c "find /tmp/vibe-check/scripts -name '*.sh' -exec chmod +x {} + 2>/dev/null || true"
vm_exec bash -c "find /tmp/vibe-check/tests -name '*.sh' -exec chmod +x {} + 2>/dev/null || true"

echo -e "${GREEN}✓ Repository copied to VM${NC}"

# Run tests
echo ""
echo -e "${BLUE}Running tests in VM...${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

TEST_FLAGS=""
if [ "$QUICK_MODE" = true ]; then
    TEST_FLAGS="--quick"
fi

TEST_RESULT=0
vm_exec bash -c "cd /tmp/vibe-check && ./tests/test-install.sh $TEST_FLAGS --mock-claude --verbose" || TEST_RESULT=$?

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
    echo "The VM is preserved for future test runs."
    echo "To start fresh: ./vm-test.sh --cleanup && ./vm-test.sh"
    exit 0
else
    echo -e "${RED}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   ✗ Tests failed in VM                               ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "To debug:"
    echo "  ./vm-test.sh --shell   # Open shell in VM"
    echo "  cd /tmp/vibe-check"
    echo "  ./tests/test-install.sh --verbose"
    exit 1
fi
