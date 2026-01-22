#!/bin/bash

# Test the vibe-check installer on a fresh Ubuntu container
#
# Usage:
#   ./scripts/test-install.sh              # Test "from repo" install
#   ./scripts/test-install.sh --curl       # Test curl install from vibecheck.wanderingstan.com
#   ./scripts/test-install.sh --shell      # Drop into shell for manual testing
#   ./scripts/test-install.sh --keep       # Keep container running after test

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse args
INTERACTIVE=false
KEEP_CONTAINER=false
USE_CURL=false
for arg in "$@"; do
    case $arg in
        --shell) INTERACTIVE=true ;;
        --keep) KEEP_CONTAINER=true ;;
        --curl) USE_CURL=true ;;
    esac
done

echo -e "${BLUE}╔═══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Vibe Check Install Test (Ubuntu)    ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════╝${NC}"
echo ""

if [ "$USE_CURL" = true ]; then
    echo -e "${YELLOW}Mode: curl install from vibecheck.wanderingstan.com${NC}"
else
    echo -e "${YELLOW}Mode: local repo install${NC}"
fi
echo ""

# Check Docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗ Docker is not installed${NC}"
    exit 1
fi

CONTAINER_NAME="vibe-check-test-$$"

cleanup() {
    if [ "$KEEP_CONTAINER" = false ]; then
        echo ""
        echo -e "${YELLOW}Cleaning up container...${NC}"
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    else
        echo ""
        echo -e "${YELLOW}Container kept running: $CONTAINER_NAME${NC}"
        echo -e "${YELLOW}  To connect: docker exec -it $CONTAINER_NAME su - testuser${NC}"
        echo -e "${YELLOW}  To remove:  docker rm -f $CONTAINER_NAME${NC}"
    fi
}
trap cleanup EXIT

# Start Ubuntu container
echo -e "${BLUE}Starting Ubuntu container...${NC}"
if [ "$USE_CURL" = true ]; then
    docker run -d --name "$CONTAINER_NAME" ubuntu:22.04 sleep infinity
else
    # Mount repo read-only for copying
    docker run -d --name "$CONTAINER_NAME" -v "$REPO_DIR:/repo-src:ro" ubuntu:22.04 sleep infinity
fi

# Install prerequisites and create test user
echo -e "${BLUE}Setting up test environment...${NC}"
docker exec "$CONTAINER_NAME" bash -c '
    apt-get update -qq
    apt-get install -y -qq python3 python3-venv git curl sudo sqlite3 > /dev/null 2>&1

    # Create test user with proper home directory
    useradd -m -s /bin/bash testuser
    echo "testuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

    echo "✓ Prerequisites installed, test user created"
'

# Mock Claude Code installation
echo -e "${BLUE}Mocking Claude Code installation...${NC}"
docker exec "$CONTAINER_NAME" bash -c '
    # Create fake claude command (installer checks for this)
    cat > /usr/local/bin/claude << "MOCK_CLAUDE"
#!/bin/bash
echo "Claude Code (mock) v1.0.0"
MOCK_CLAUDE
    chmod +x /usr/local/bin/claude

    # Create Claude Code directory structure
    CLAUDE_DIR="/home/testuser/.claude"
    PROJECT_DIR="$CLAUDE_DIR/projects/-home-testuser-test-project"
    mkdir -p "$PROJECT_DIR"

    # Create a realistic conversation log file
    cat > "$PROJECT_DIR/conversations.jsonl" << "MOCK_LOG"
{"type":"system","message":"Claude Code session started","timestamp":"2025-01-21T10:00:00.000Z","sessionId":"test-session-123","version":"1.0.0"}
{"type":"user","message":"Hello, can you help me write a test?","timestamp":"2025-01-21T10:00:01.000Z","sessionId":"test-session-123"}
{"type":"assistant","message":"Of course! I would be happy to help you write a test. What kind of test would you like to create?","timestamp":"2025-01-21T10:00:02.000Z","sessionId":"test-session-123"}
{"type":"tool_use","tool":"Read","input":{"file_path":"/home/testuser/test-project/main.py"},"timestamp":"2025-01-21T10:00:03.000Z","sessionId":"test-session-123"}
{"type":"tool_result","tool":"Read","output":"# Main application file\nprint(\"hello world\")","timestamp":"2025-01-21T10:00:04.000Z","sessionId":"test-session-123"}
MOCK_LOG

    chown -R testuser:testuser "$CLAUDE_DIR"
    echo "✓ Claude Code mocked (fake command + sample conversation log)"
'

# For local mode, copy repo to writable location (excluding venv which has host binaries)
if [ "$USE_CURL" = false ]; then
    echo -e "${BLUE}Copying repo to container...${NC}"
    docker exec "$CONTAINER_NAME" bash -c '
        cp -r /repo-src /home/testuser/vibe-check
        rm -rf /home/testuser/vibe-check/venv  # Remove host venv (macOS binaries wont work)
        chown -R testuser:testuser /home/testuser/vibe-check
    '
fi

if [ "$INTERACTIVE" = true ]; then
    echo ""
    echo -e "${YELLOW}Dropping into shell as testuser.${NC}"
    if [ "$USE_CURL" = true ]; then
        echo -e "${YELLOW}Run: curl -fsSL https://vibecheck.wanderingstan.com/install.sh | bash${NC}"
    else
        echo -e "${YELLOW}Run: cd ~/vibe-check && ./scripts/install.sh${NC}"
    fi
    echo ""
    docker exec -it "$CONTAINER_NAME" su - testuser
    exit 0
fi

# Run the installer
echo -e "${BLUE}Running installer...${NC}"
echo ""

if [ "$USE_CURL" = true ]; then
    # Test curl install from website
    docker exec "$CONTAINER_NAME" su - testuser -c '
        curl -fsSL https://vibecheck.wanderingstan.com/install.sh | bash
    '
else
    # Test local repo install (runs in "from repo" mode)
    docker exec "$CONTAINER_NAME" su - testuser -c '
        cd ~/vibe-check && ./scripts/install.sh --skip-auth 2>&1
    '
fi

echo ""
echo -e "${BLUE}╔═══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Verifying Installation              ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════╝${NC}"
echo ""

# Run verification tests
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local name="$1"
    local cmd="$2"

    if docker exec "$CONTAINER_NAME" su - testuser -c "$cmd" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ $name${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ $name${NC}"
        ((TESTS_FAILED++))
    fi
}

# Determine install location based on mode
if [ "$USE_CURL" = true ]; then
    VIBE_CHECK_CMD='~/.vibe-check/vibe-check'
    VENV_PATH='~/.vibe-check/venv/bin/activate'
else
    # "From repo" mode uses ~/vibe-check
    VIBE_CHECK_CMD='~/vibe-check/vibe-check'
    VENV_PATH='~/vibe-check/venv/bin/activate'
fi

# Test 1: vibe-check wrapper exists
run_test "vibe-check wrapper exists" "test -x $VIBE_CHECK_CMD"

# Test 2: Virtual environment created
run_test "Virtual environment created" "test -f $VENV_PATH"

# Test 3: Skills installed
run_test "Skills installed" "test -d ~/.claude/skills"

# Test 4: Daemon can be started
run_test "Daemon can start" "$VIBE_CHECK_CMD start && sleep 2"

# Test 5: Status shows running
run_test "Status shows running" "$VIBE_CHECK_CMD status | grep -qi running"

# Test 6: Config file created
run_test "Config file created" "test -f ~/.vibe-check/config.json"

# Test 7: Database created
run_test "Database created" "test -f ~/.vibe-check/vibe_check.db"

# Test 8: Events processed from mock log (give daemon time to process)
sleep 2
run_test "Events in database" "sqlite3 ~/.vibe-check/vibe_check.db 'SELECT COUNT(*) FROM conversation_events' | grep -v '^0$'"

# Test 9: Can stop daemon
run_test "Daemon can stop" "$VIBE_CHECK_CMD stop"

echo ""
echo -e "${BLUE}═══════════════════════════════════════${NC}"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"

    # Show debug info
    echo ""
    echo -e "${YELLOW}Debug info:${NC}"
    docker exec "$CONTAINER_NAME" su - testuser -c "
        echo '=== Config ==='
        cat ~/.vibe-check/config.json 2>/dev/null || echo '(no config)'
        echo ''
        echo '=== Status ==='
        $VIBE_CHECK_CMD status 2>&1 || echo '(status failed)'
        echo ''
        echo '=== Logs ==='
        tail -20 ~/.vibe-check/vibe-check.log 2>/dev/null || echo '(no logs)'
    "
    exit 1
fi
