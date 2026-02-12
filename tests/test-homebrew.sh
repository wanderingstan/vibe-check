#!/bin/bash
#
# Homebrew Installation Test Suite
#
# Tests vibe-check installation via Homebrew formula to ensure all
# Homebrew-specific features work correctly (brew services, proper paths, etc.)
#
# Usage:
#   ./test-homebrew.sh              # Run full test suite
#   ./test-homebrew.sh --quick      # Skip time-consuming tests
#   ./test-homebrew.sh --verbose    # Show detailed output
#
# Exit codes:
#   0 = All tests passed
#   1 = One or more tests failed
#   2 = Prerequisites not met

set -e  # Exit on error (but we'll catch them)

# Test configuration
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
QUICK_MODE=false
VERBOSE=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --quick) QUICK_MODE=true ;;
        --verbose) VERBOSE=true ;;
        --help)
            echo "Usage: $0 [--quick] [--verbose] [--help]"
            echo ""
            echo "Options:"
            echo "  --quick       Skip time-consuming tests"
            echo "  --verbose     Show detailed output"
            exit 0
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}  $1${NC}"
    fi
}

log_info() {
    echo -e "${BLUE}$1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

log_error() {
    echo -e "${RED}✗ $1${NC}"
}

log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Test runner
run_test() {
    local test_name="$1"
    local test_func="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "Testing $test_name... "

    if $test_func; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC}"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗${NC}"
        return 1
    fi
}

# ============================================================================
# PREREQUISITE TESTS
# ============================================================================

test_homebrew_installed() {
    log_verbose "Checking Homebrew installation..."

    if ! command -v brew &> /dev/null; then
        log_error "Homebrew not found"
        return 1
    fi
    log_verbose "✓ Homebrew found: $(brew --version | head -n1)"

    return 0
}

test_vibe_check_brew_package() {
    log_verbose "Checking vibe-check Homebrew package..."

    if ! brew list vibe-check &> /dev/null; then
        log_error "vibe-check not installed via Homebrew"
        log_info "Install with: brew install wanderingstan/vibe-check/vibe-check"
        return 1
    fi
    log_verbose "✓ vibe-check Homebrew package installed"

    return 0
}

# ============================================================================
# PATH AND INSTALLATION TESTS
# ============================================================================

test_vibe_check_command() {
    log_verbose "Checking vibe-check command availability..."

    if ! command -v vibe-check &> /dev/null; then
        log_error "vibe-check command not in PATH"
        return 1
    fi

    local cmd_path=$(which vibe-check)
    log_verbose "✓ vibe-check command found: $cmd_path"

    # Verify it's the Homebrew version
    if [[ ! "$cmd_path" =~ ^/opt/homebrew/bin/vibe-check|^/usr/local/bin/vibe-check ]]; then
        log_warning "vibe-check not from Homebrew location (found at $cmd_path)"
    fi

    return 0
}

test_homebrew_paths() {
    log_verbose "Checking Homebrew-specific paths..."

    # Check Cellar location
    local cellar_path="/opt/homebrew/Cellar/vibe-check"
    if [ ! -d "$cellar_path" ] && [ ! -d "/usr/local/Cellar/vibe-check" ]; then
        log_error "vibe-check not found in Homebrew Cellar"
        return 1
    fi
    log_verbose "✓ vibe-check found in Homebrew Cellar"

    # Check bin symlink
    if [ ! -f "/opt/homebrew/bin/vibe-check" ] && [ ! -f "/usr/local/bin/vibe-check" ]; then
        log_error "vibe-check not found in Homebrew bin"
        return 1
    fi
    log_verbose "✓ vibe-check bin symlink exists"

    # Check share directory (MCP server, skills)
    local share_path="/opt/homebrew/share/vibe-check"
    if [ ! -d "$share_path" ] && [ ! -d "/usr/local/share/vibe-check" ]; then
        log_error "vibe-check share directory not found"
        return 1
    fi
    log_verbose "✓ vibe-check share directory exists"

    return 0
}

test_data_directory_symlink() {
    log_verbose "Checking data directory and symlink..."

    # Check ~/.vibe-check exists
    if [ ! -d "$HOME/.vibe-check" ]; then
        log_error "Data directory ~/.vibe-check not found"
        return 1
    fi
    log_verbose "✓ Data directory ~/.vibe-check exists"

    # Check Homebrew var symlink (may not exist until first run)
    local var_path="/opt/homebrew/var/vibe-check"
    if [ ! -e "$var_path" ] && [ ! -e "/usr/local/var/vibe-check" ]; then
        log_verbose "⚠ Homebrew var symlink not created yet (created on first run)"
    else
        log_verbose "✓ Homebrew var symlink exists"
    fi

    return 0
}

# ============================================================================
# CONFIGURATION AND DATABASE TESTS
# ============================================================================

test_config_file() {
    log_verbose "Checking configuration file..."

    local config_file="$HOME/.vibe-check/config.json"

    # Config may not exist until first run
    if [ ! -f "$config_file" ]; then
        log_verbose "⚠ Config file not created yet (created on first daemon start)"
        return 0
    fi

    # Validate JSON syntax
    if ! python3 -m json.tool "$config_file" &> /dev/null; then
        log_error "Config file has invalid JSON"
        return 1
    fi
    log_verbose "✓ Config file is valid JSON"

    return 0
}

test_database_schema() {
    log_verbose "Checking database schema..."

    local db_file="$HOME/.vibe-check/vibe_check.db"

    # Database may not exist until first run
    if [ ! -f "$db_file" ]; then
        log_verbose "⚠ Database not created yet (created on first daemon start)"
        return 0
    fi

    # Check for required tables
    if ! sqlite3 "$db_file" "SELECT name FROM sqlite_master WHERE type='table' AND name='conversation_events';" 2>/dev/null | grep -q "conversation_events"; then
        log_error "Database missing conversation_events table"
        return 1
    fi
    log_verbose "✓ Database has conversation_events table"

    if ! sqlite3 "$db_file" "SELECT name FROM sqlite_master WHERE type='table' AND name='conversation_file_state';" 2>/dev/null | grep -q "conversation_file_state"; then
        log_error "Database missing conversation_file_state table"
        return 1
    fi
    log_verbose "✓ Database has conversation_file_state table"

    return 0
}

# ============================================================================
# SKILLS AND MCP TESTS
# ============================================================================

test_skills_installed() {
    log_verbose "Checking Claude Code skills installation..."

    local skills_dir="$HOME/.claude/skills"

    if [ ! -d "$skills_dir" ]; then
        log_warning "Skills directory ~/.claude/skills not found"
        return 0  # Not a failure - Claude Code may not be installed
    fi

    # Check for at least one vibe-check skill
    local skill_count=$(find "$skills_dir" -type d -name "vibe-check-*" 2>/dev/null | wc -l)
    if [ "$skill_count" -eq 0 ]; then
        log_warning "No vibe-check skills found in ~/.claude/skills"
        return 0  # Not a failure - skills may not be installed yet
    fi

    log_verbose "✓ Found $skill_count vibe-check skill(s)"
    return 0
}

test_mcp_server_files() {
    log_verbose "Checking MCP server files..."

    local share_path="/opt/homebrew/share/vibe-check/mcp-server"
    if [ ! -d "$share_path" ]; then
        share_path="/usr/local/share/vibe-check/mcp-server"
    fi

    if [ ! -d "$share_path" ]; then
        log_error "MCP server directory not found in Homebrew share"
        return 1
    fi

    if [ ! -f "$share_path/server.py" ]; then
        log_error "MCP server.py not found"
        return 1
    fi

    log_verbose "✓ MCP server files present"
    return 0
}

# ============================================================================
# BREW SERVICES TESTS
# ============================================================================

test_brew_services() {
    if [ "$QUICK_MODE" = true ]; then
        log_info "Skipping brew services test (quick mode)"
        return 0
    fi

    log_verbose "Testing brew services integration..."

    # Stop any running instance first
    brew services stop vibe-check 2>/dev/null || true
    sleep 1

    # Start via brew services
    if ! brew services start vibe-check 2>&1 | grep -q "Successfully started"; then
        log_error "Failed to start vibe-check via brew services"
        return 1
    fi
    log_verbose "✓ brew services start successful"

    # Give daemon time to start
    sleep 3

    # Check if running
    if ! brew services list | grep vibe-check | grep -q "started"; then
        log_error "vibe-check not running after brew services start"
        brew services stop vibe-check 2>/dev/null || true
        return 1
    fi
    log_verbose "✓ vibe-check running via brew services"

    # Stop via brew services
    if ! brew services stop vibe-check 2>&1 | grep -q "Successfully stopped"; then
        log_error "Failed to stop vibe-check via brew services"
        return 1
    fi
    log_verbose "✓ brew services stop successful"

    return 0
}

# ============================================================================
# FUNCTIONAL TESTS
# ============================================================================

test_daemon_start_stop() {
    if [ "$QUICK_MODE" = true ]; then
        log_info "Skipping daemon test (quick mode)"
        return 0
    fi

    log_verbose "Testing daemon start/stop..."

    # Stop any running instance
    vibe-check stop 2>/dev/null || true
    brew services stop vibe-check 2>/dev/null || true
    sleep 1

    # Start daemon
    if ! vibe-check start 2>&1 | grep -q "started"; then
        log_error "Failed to start daemon"
        return 1
    fi
    log_verbose "✓ Daemon started"

    # Give daemon time to initialize
    sleep 3

    # Check status
    if ! vibe-check status 2>&1 | grep -q "running"; then
        log_error "Daemon not running after start"
        vibe-check stop 2>/dev/null || true
        return 1
    fi
    log_verbose "✓ Daemon status shows running"

    # Stop daemon
    if ! vibe-check stop 2>&1 | grep -q "stopped"; then
        log_error "Failed to stop daemon"
        return 1
    fi
    log_verbose "✓ Daemon stopped"

    return 0
}

test_database_operations() {
    log_verbose "Testing database operations..."

    local db_file="$HOME/.vibe-check/vibe_check.db"

    # Ensure daemon has been run at least once
    if [ ! -f "$db_file" ]; then
        log_verbose "Starting daemon to initialize database..."
        vibe-check start 2>/dev/null || true
        sleep 3
        vibe-check stop 2>/dev/null || true
        sleep 1
    fi

    if [ ! -f "$db_file" ]; then
        log_error "Database not created"
        return 1
    fi

    # Test read-only access
    if ! sqlite3 "file:$db_file?mode=ro" "SELECT COUNT(*) FROM conversation_events" &>/dev/null; then
        log_error "Read-only database access failed"
        return 1
    fi
    log_verbose "✓ Read-only database access works"

    # Verify schema
    local tables=$(sqlite3 "$db_file" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" 2>/dev/null)
    if ! echo "$tables" | grep -q "conversation_events"; then
        log_error "Database schema missing expected tables"
        return 1
    fi

    log_verbose "✓ Database operations work"
    return 0
}

# ============================================================================
# MAIN TEST RUNNER
# ============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Homebrew Installation Test Suite                   ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_summary() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Test Summary${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Total tests run: $TESTS_RUN"
    echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "${RED}Failed: $TESTS_FAILED${NC}"
        return 1
    fi
    echo ""

    return 0
}

main() {
    print_header

    echo -e "${BOLD}Running Prerequisite Tests...${NC}"
    run_test "Homebrew Installation" test_homebrew_installed || exit 2
    run_test "Vibe-Check Brew Package" test_vibe_check_brew_package || exit 2

    echo ""
    echo -e "${BOLD}Running Path and Installation Tests...${NC}"
    run_test "Vibe-Check Command" test_vibe_check_command
    run_test "Homebrew Paths" test_homebrew_paths
    run_test "Data Directory Symlink" test_data_directory_symlink

    echo ""
    echo -e "${BOLD}Running Configuration Tests...${NC}"
    run_test "Configuration File" test_config_file
    run_test "Database Schema" test_database_schema

    echo ""
    echo -e "${BOLD}Running Skills and MCP Tests...${NC}"
    run_test "Skills Installation" test_skills_installed
    run_test "MCP Server Files" test_mcp_server_files

    echo ""
    echo -e "${BOLD}Running Brew Services Tests...${NC}"
    run_test "Brew Services" test_brew_services

    echo ""
    echo -e "${BOLD}Running Functional Tests...${NC}"
    run_test "Daemon Start/Stop" test_daemon_start_stop
    run_test "Database Operations" test_database_operations

    # Print summary and exit with appropriate code
    if print_summary; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
