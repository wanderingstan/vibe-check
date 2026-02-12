#!/bin/bash
#
# VM-based Homebrew Testing with Tart (macOS Virtualization)
#
# Tests vibe-check Homebrew installation in a clean macOS VM.
# This validates the production Homebrew install path (not direct install.sh).
#
# Prerequisites:
#   brew install cirruslabs/cli/tart
#
# Usage:
#   ./vm-test-homebrew.sh                    # Test published formula
#   ./vm-test-homebrew.sh --local            # Test local formula file
#   ./vm-test-homebrew.sh --quick            # Quick tests only
#   ./vm-test-homebrew.sh --setup            # Set up VM only
#   ./vm-test-homebrew.sh --cleanup          # Remove VM
#   ./vm-test-homebrew.sh --shell            # Open shell in VM

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
VM_NAME="vibe-check-homebrew-test"
BASE_IMAGE="ghcr.io/cirruslabs/macos-sonoma-base:latest"
QUICK_MODE=false
SETUP_ONLY=false
CLEANUP_ONLY=false
SHELL_ONLY=false
LOCAL_FORMULA=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --quick) QUICK_MODE=true ;;
        --setup) SETUP_ONLY=true ;;
        --cleanup) CLEANUP_ONLY=true ;;
        --shell) SHELL_ONLY=true ;;
        --local) LOCAL_FORMULA=true ;;
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --setup    Set up VM only, don't run tests"
            echo "  --quick    Run quick tests only"
            echo "  --local    Test local formula instead of published"
            echo "  --cleanup  Remove the test VM"
            echo "  --shell    Open a shell in the VM"
            echo "  --help     Show this help"
            echo ""
            echo "Prerequisites:"
            echo "  brew install cirruslabs/cli/tart"
            echo ""
            echo "Examples:"
            echo "  ./vm-test-homebrew.sh              # Test published formula"
            echo "  ./vm-test-homebrew.sh --local      # Test local formula"
            echo "  ./vm-test-homebrew.sh --cleanup    # Clean up VM"
            exit 0
            ;;
    esac
done

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Vibe Check Homebrew VM Testing (Tart)              ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "$LOCAL_FORMULA" = true ]; then
    echo -e "${YELLOW}Mode: Testing LOCAL formula${NC}"
else
    echo -e "${BLUE}Mode: Testing PUBLISHED formula${NC}"
fi
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
    echo "To run tests: ./vm-test-homebrew.sh"
    echo "To open shell: ./vm-test-homebrew.sh --shell"
    echo "To clean up: ./vm-test-homebrew.sh --cleanup"
    exit 0
fi

# Shell mode
if [ "$SHELL_ONLY" = true ]; then
    echo -e "${BLUE}Starting VM and opening shell...${NC}"
    tart run "$VM_NAME"
    exit 0
fi

# Run tests in VM
echo ""
echo -e "${BLUE}Starting VM...${NC}"

# Start VM in background
tart run "$VM_NAME" &
VM_PID=$!

# Function to run commands in VM
vm_exec() {
    tart exec "$VM_NAME" -- "$@"
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
    echo -e "${YELLOW}Possible issues:${NC}"
    echo "1. The base image may not have guest agent installed"
    echo "2. macOS may be waiting for first-boot setup"
    echo "3. The VM needs more resources (CPU/RAM)"
    echo ""
    echo -e "${YELLOW}Try these steps:${NC}"
    echo "  1. Clean up and retry with fresh VM:"
    echo "     ./vm-test-homebrew.sh --cleanup && ./vm-test-homebrew.sh"
    echo ""
    echo "  2. Open VM interactively to complete setup:"
    echo "     ./vm-test-homebrew.sh --shell"
    echo "     (Complete any macOS setup prompts, then exit and retry)"
    echo ""
    echo "  3. Check Tart documentation for your version:"
    echo "     tart --version"
    echo "     Visit: https://tart.run"

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
    vm_exec /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add Homebrew to PATH for this session
    vm_exec bash -c 'eval "$(/opt/homebrew/bin/brew shellenv)"'
fi
echo -e "${GREEN}✓ Homebrew installed${NC}"

# Create mock Claude Code directory (required for vibe-check)
echo "Setting up mock Claude Code directory..."
vm_exec mkdir -p ~/.claude/projects
echo -e "${GREEN}✓ Mock Claude Code directory created${NC}"

# Install vibe-check via Homebrew
echo ""
echo -e "${BLUE}Installing vibe-check via Homebrew...${NC}"

if [ "$LOCAL_FORMULA" = true ]; then
    # Test local formula
    echo "Copying local formula to VM..."

    # Check if Formula/vibe-check.rb exists
    if [ ! -f "$REPO_ROOT/Formula/vibe-check.rb" ]; then
        echo -e "${RED}✗ Local formula not found: $REPO_ROOT/Formula/vibe-check.rb${NC}"
        tart stop "$VM_NAME" 2>/dev/null || true
        exit 1
    fi

    # Copy formula to VM
    vm_exec mkdir -p /tmp/homebrew-test
    tart cp "$REPO_ROOT/Formula/vibe-check.rb" "$VM_NAME:/tmp/homebrew-test/vibe-check.rb"

    echo "Installing from local formula..."
    if ! vm_exec bash -c 'eval "$(/opt/homebrew/bin/brew shellenv)" && brew install --build-from-source /tmp/homebrew-test/vibe-check.rb'; then
        echo -e "${RED}✗ Failed to install from local formula${NC}"
        tart stop "$VM_NAME" 2>/dev/null || true
        exit 1
    fi
    echo -e "${GREEN}✓ Installed from local formula${NC}"
else
    # Test published formula
    echo "Tapping wanderingstan/vibe-check..."
    if ! vm_exec bash -c 'eval "$(/opt/homebrew/bin/brew shellenv)" && brew tap wanderingstan/vibe-check'; then
        echo -e "${RED}✗ Failed to tap wanderingstan/vibe-check${NC}"
        tart stop "$VM_NAME" 2>/dev/null || true
        exit 1
    fi

    echo "Installing vibe-check..."
    if ! vm_exec bash -c 'eval "$(/opt/homebrew/bin/brew shellenv)" && brew install vibe-check'; then
        echo -e "${RED}✗ Failed to install vibe-check${NC}"
        tart stop "$VM_NAME" 2>/dev/null || true
        exit 1
    fi
    echo -e "${GREEN}✓ Installed from published formula${NC}"
fi

# Copy test script to VM
echo ""
echo -e "${BLUE}Copying test script to VM...${NC}"
vm_exec mkdir -p /tmp/vibe-check-tests
tart cp "$REPO_ROOT/tests/test-homebrew.sh" "$VM_NAME:/tmp/vibe-check-tests/test-homebrew.sh"
vm_exec chmod +x /tmp/vibe-check-tests/test-homebrew.sh
echo -e "${GREEN}✓ Test script copied${NC}"

# Run tests
echo ""
echo -e "${BLUE}Running Homebrew tests in VM...${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

TEST_FLAGS=""
if [ "$QUICK_MODE" = true ]; then
    TEST_FLAGS="--quick"
fi

TEST_RESULT=0
vm_exec bash -c "eval \"\$(/opt/homebrew/bin/brew shellenv)\" && /tmp/vibe-check-tests/test-homebrew.sh $TEST_FLAGS --verbose" || TEST_RESULT=$?

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
    echo -e "${GREEN}║   ✓ All Homebrew tests passed in VM!                 ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "The VM is preserved for future test runs."
    echo "To start fresh: ./vm-test-homebrew.sh --cleanup && ./vm-test-homebrew.sh"
    exit 0
else
    echo -e "${RED}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   ✗ Homebrew tests failed in VM                      ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "To debug:"
    echo "  ./vm-test-homebrew.sh --shell   # Open shell in VM"
    echo "  # Then in VM:"
    echo "  eval \"\$(/opt/homebrew/bin/brew shellenv)\""
    echo "  /tmp/vibe-check-tests/test-homebrew.sh --verbose"
    exit 1
fi
