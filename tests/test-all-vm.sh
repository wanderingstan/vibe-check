#!/bin/bash
#
# Master VM Test Suite
#
# Runs both direct install and Homebrew install tests in VMs.
# Reports results from both and fails if either test fails.
#
# Usage:
#   ./test-all-vm.sh              # Run both test suites
#   ./test-all-vm.sh --quick      # Quick mode for both
#   ./test-all-vm.sh --setup      # Set up both VMs
#   ./test-all-vm.sh --cleanup    # Clean up both VMs
#
# Exit codes:
#   0 = All tests passed
#   1 = One or more test suites failed
#   2 = Prerequisites not met

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
QUICK_MODE=false
SETUP_ONLY=false
CLEANUP_ONLY=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --quick) QUICK_MODE=true ;;
        --setup) SETUP_ONLY=true ;;
        --cleanup) CLEANUP_ONLY=true ;;
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Runs both VM test suites:"
            echo "  1. Direct install (vm-test.sh)"
            echo "  2. Homebrew install (vm-test-homebrew.sh)"
            echo ""
            echo "Options:"
            echo "  --quick    Run quick tests only"
            echo "  --setup    Set up both VMs only"
            echo "  --cleanup  Clean up both VMs"
            echo "  --help     Show this help"
            echo ""
            echo "Prerequisites:"
            echo "  brew install cirruslabs/cli/tart"
            exit 0
            ;;
    esac
done

# Build flags for sub-scripts
FLAGS=""
if [ "$QUICK_MODE" = true ]; then
    FLAGS="--quick"
fi
if [ "$SETUP_ONLY" = true ]; then
    FLAGS="--setup"
fi
if [ "$CLEANUP_ONLY" = true ]; then
    FLAGS="--cleanup"
fi

echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Vibe Check Master VM Test Suite                    ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

# Track results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_SUITES=()

# Check prerequisites
if ! command -v tart &> /dev/null; then
    echo -e "${RED}✗ Tart not installed${NC}"
    echo ""
    echo "Install Tart with:"
    echo "  brew install cirruslabs/cli/tart"
    exit 2
fi

# For setup/cleanup, just run both scripts
if [ "$SETUP_ONLY" = true ] || [ "$CLEANUP_ONLY" = true ]; then
    echo -e "${BLUE}Running both VM scripts with $FLAGS...${NC}"
    echo ""

    "$TEST_DIR/vm-test.sh" $FLAGS
    echo ""
    "$TEST_DIR/vm-test-homebrew.sh" $FLAGS

    exit 0
fi

# Run direct install test
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}Test Suite 1: Direct Install (vm-test.sh)${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""

TESTS_RUN=$((TESTS_RUN + 1))
if "$TEST_DIR/vm-test.sh" $FLAGS; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo ""
    echo -e "${GREEN}✓ Direct install tests PASSED${NC}"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_SUITES+=("Direct Install (vm-test.sh)")
    echo ""
    echo -e "${RED}✗ Direct install tests FAILED${NC}"
fi

echo ""
echo ""

# Run Homebrew install test
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}Test Suite 2: Homebrew Install (vm-test-homebrew.sh)${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""

TESTS_RUN=$((TESTS_RUN + 1))
if "$TEST_DIR/vm-test-homebrew.sh" $FLAGS; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo ""
    echo -e "${GREEN}✓ Homebrew install tests PASSED${NC}"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_SUITES+=("Homebrew Install (vm-test-homebrew.sh)")
    echo ""
    echo -e "${RED}✗ Homebrew install tests FAILED${NC}"
fi

# Print final summary
echo ""
echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Final Test Summary                                  ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Test suites run:    $TESTS_RUN"
echo -e "Passed:             ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:             ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Failed test suites:${NC}"
    for suite in "${FAILED_SUITES[@]}"; do
        echo -e "  ${RED}✗${NC} $suite"
    done
    echo ""
    echo -e "${YELLOW}To debug individual suites:${NC}"
    echo "  ./tests/vm-test.sh --shell"
    echo "  ./tests/vm-test-homebrew.sh --shell"
    echo ""
    exit 1
else
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✓ All VM test suites passed!                       ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    exit 0
fi
