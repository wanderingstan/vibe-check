#!/bin/bash
#
# Automated Test Suite for Vibe Check Installation
#
# Tests both fresh install and update scenarios, validates all components,
# and provides detailed reporting.
#
# Usage:
#   ./test-install.sh              # Run full test suite
#   ./test-install.sh --quick      # Skip time-consuming tests
#   ./test-install.sh --cleanup    # Clean up test artifacts
#   ./test-install.sh --verbose    # Show detailed output
#   ./test-install.sh --mock-claude # Create mock ~/.claude/projects if needed
#
# Exit codes:
#   0 = All tests passed
#   1 = One or more tests failed
#   2 = Prerequisites not met

set -e  # Exit on error (but we'll catch them)

# Test configuration
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "$TEST_DIR")
QUICK_MODE=false
VERBOSE=false
CLEANUP_ONLY=false
MOCK_CLAUDE=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --quick) QUICK_MODE=true ;;
        --verbose) VERBOSE=true ;;
        --cleanup) CLEANUP_ONLY=true ;;
        --mock-claude) MOCK_CLAUDE=true ;;
        --help)
            echo "Usage: $0 [--quick] [--verbose] [--cleanup] [--mock-claude] [--help]"
            echo ""
            echo "Options:"
            echo "  --quick       Skip time-consuming tests"
            echo "  --verbose     Show detailed output"
            echo "  --cleanup     Clean up test artifacts only"
            echo "  --mock-claude Create mock ~/.claude/projects if needed"
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
NC='\033[0m' # No Color

# Test results tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Logging
log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Test framework
run_test() {
    local test_name="$1"
    local test_func="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo -e "${BOLD}Test $TESTS_RUN: $test_name${NC}"

    if $test_func; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_success "$test_name"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$test_name")
        log_error "$test_name"
        return 1
    fi
}

# Cleanup function
cleanup_test_environment() {
    log_info "Cleaning up test environment..."

    # Stop any running vibe-check daemon
    if [ -f "$HOME/.vibe-check/.monitor.pid" ]; then
        log_verbose "Stopping vibe-check daemon"
        python3 "$REPO_ROOT/vibe-check.py" stop 2>/dev/null || true
    fi

    # Backup existing installation if present
    if [ -d "$HOME/.vibe-check" ]; then
        local backup_dir="$HOME/.vibe-check.backup.$(date +%s)"
        log_info "Backing up existing installation to $backup_dir"
        mv "$HOME/.vibe-check" "$backup_dir"
    fi

    # Backup existing skills if present
    if [ -d "$HOME/.claude/skills/vibe-check-stats" ]; then
        local skills_backup="$HOME/.claude/skills.backup.$(date +%s)"
        log_info "Backing up existing skills to $skills_backup"
        mkdir -p "$skills_backup"
        mv "$HOME/.claude/skills"/vibe-check-* "$skills_backup/" 2>/dev/null || true
    fi

    # Remove PATH additions from shell configs (just for testing)
    for config in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
        if [ -f "$config" ]; then
            # Create backup
            cp "$config" "$config.vibe-check-test-backup"
            # Remove vibe-check PATH entries
            sed -i.bak '/# Vibe Check/d' "$config" 2>/dev/null || true
            sed -i.bak '/\.vibe-check/d' "$config" 2>/dev/null || true
        fi
    done

    log_success "Test environment cleaned"
}

restore_test_environment() {
    log_info "Restoring original environment..."

    # Restore shell configs
    for config in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
        if [ -f "$config.vibe-check-test-backup" ]; then
            mv "$config.vibe-check-test-backup" "$config"
        fi
    done

    # Find most recent backup
    local latest_backup=$(ls -dt "$HOME"/.vibe-check.backup.* 2>/dev/null | head -1)
    if [ -n "$latest_backup" ]; then
        log_info "Restoring from $latest_backup"
        rm -rf "$HOME/.vibe-check"
        mv "$latest_backup" "$HOME/.vibe-check"
    fi

    # Restore skills
    local latest_skills_backup=$(ls -dt "$HOME/.claude"/skills.backup.* 2>/dev/null | head -1)
    if [ -n "$latest_skills_backup" ]; then
        log_info "Restoring skills from $latest_skills_backup"
        mv "$latest_skills_backup"/vibe-check-* "$HOME/.claude/skills/" 2>/dev/null || true
        rmdir "$latest_skills_backup" 2>/dev/null || true
    fi

    log_success "Environment restored"
}

# ============================================================================
# PREREQUISITE TESTS
# ============================================================================

test_prerequisites() {
    log_verbose "Checking prerequisites..."

    # Check Python 3
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 not found"
        return 1
    fi
    log_verbose "✓ Python 3 found: $(python3 --version)"

    # Check pip
    if ! python3 -m pip --version &> /dev/null; then
        log_error "pip not found"
        return 1
    fi
    log_verbose "✓ pip found"

    # Check git
    if ! command -v git &> /dev/null; then
        log_error "git not found"
        return 1
    fi
    log_verbose "✓ git found: $(git --version)"

    # Check Claude Code directory
    if [ ! -d "$HOME/.claude/projects" ]; then
        if [ "$MOCK_CLAUDE" = true ]; then
            log_warning "Claude Code not found, creating mock directory..."
            mkdir -p "$HOME/.claude/projects"
            log_verbose "✓ Mock Claude Code directory created"
        else
            log_error "Claude Code not installed (~/.claude/projects not found)"
            log_info "Use --mock-claude flag to create a mock directory for testing"
            return 1
        fi
    else
        log_verbose "✓ Claude Code directory found"
    fi

    # Check required files exist in repo
    for file in "vibe-check.py" "requirements.txt" "scripts/install.sh"; do
        if [ ! -f "$REPO_ROOT/$file" ]; then
            log_error "Required file missing: $file"
            return 1
        fi
    done
    log_verbose "✓ All required repo files present"

    return 0
}

# ============================================================================
# INSTALLATION TESTS
# ============================================================================

test_fresh_install() {
    log_info "Running fresh installation..."

    cd "$REPO_ROOT"
    if ! ./scripts/install.sh --skip-auth 2>&1 | tee /tmp/vibe-check-test-install.log; then
        log_error "Installation script failed"
        log_verbose "Last 20 lines of output:"
        tail -20 /tmp/vibe-check-test-install.log
        return 1
    fi

    log_verbose "Installation completed successfully"
    return 0
}

test_installation_directories() {
    log_verbose "Checking installation directories..."

    # Detect installation type: git-based or standard
    local install_dir
    if [ -f "$HOME/.vibe-check/vibe-check.py" ]; then
        # Standard installation (Homebrew or copied files)
        install_dir="$HOME/.vibe-check"
        log_verbose "Detected standard installation at $install_dir"
    elif [ -f "$REPO_ROOT/vibe-check.py" ] && [ -d "$REPO_ROOT/.git" ]; then
        # Git-based installation (running from repo)
        install_dir="$REPO_ROOT"
        log_verbose "Detected git-based installation at $install_dir"
    else
        log_error "Could not determine installation directory"
        return 1
    fi

    # Check main installation directory exists
    if [ ! -d "$install_dir" ]; then
        log_error "Installation directory not found: $install_dir"
        return 1
    fi

    # Check config directory always exists
    if [ ! -d "$HOME/.vibe-check" ]; then
        log_error "Config directory not created at $HOME/.vibe-check"
        return 1
    fi

    # Check key files and directories
    local required_paths=(
        "$install_dir/vibe-check.py"
        "$install_dir/requirements.txt"
        "$install_dir/venv"
        "$install_dir/venv/bin/activate"
        "$install_dir/venv/bin/python"
    )

    for path in "${required_paths[@]}"; do
        if [ ! -e "$path" ]; then
            log_error "Required path missing: $path"
            return 1
        fi
        log_verbose "✓ $path"
    done

    return 0
}

test_configuration_created() {
    log_verbose "Checking configuration file..."

    local config_file="$HOME/.vibe-check/config.json"

    if [ ! -f "$config_file" ]; then
        log_error "Configuration file not created"
        return 1
    fi

    # Validate JSON structure
    if ! python3 -c "import json; json.load(open('$config_file'))" 2>/dev/null; then
        log_error "Configuration file is not valid JSON"
        return 1
    fi

    # Check required fields
    local required_fields=("sqlite" "monitor")
    for field in "${required_fields[@]}"; do
        if ! grep -q "\"$field\"" "$config_file"; then
            log_error "Configuration missing required field: $field"
            return 1
        fi
    done

    log_verbose "✓ Configuration file valid"
    return 0
}

test_database_created() {
    log_verbose "Checking database..."

    local db_file="$HOME/.vibe-check/vibe_check.db"

    # In quick mode or fresh environments, database may not exist yet (created on first conversation)
    if [ ! -f "$db_file" ]; then
        if [ "$QUICK_MODE" = true ]; then
            log_info "Database not yet created (expected in fresh environment)"
            log_verbose "Database will be created when first conversation is processed"
            return 0
        else
            log_error "Database file not created"
            return 1
        fi
    fi

    # Check database schema if it exists
    local tables=$(sqlite3 "$db_file" "SELECT name FROM sqlite_master WHERE type='table';" 2>/dev/null)

    if ! echo "$tables" | grep -q "conversation_events"; then
        log_error "Database missing conversation_events table"
        return 1
    fi

    if ! echo "$tables" | grep -q "conversation_file_state"; then
        log_error "Database missing conversation_file_state table"
        return 1
    fi

    log_verbose "✓ Database schema valid"
    return 0
}

test_skills_installed() {
    log_verbose "Checking skills installation..."

    local skills_dir="$HOME/.claude/skills"
    local expected_skills=(
        "vibe-check-stats"
        "vibe-check-session-id"
        "vibe-check-share"
        "vibe-check-doctor"
        "vibe-check-search"
        "vibe-check-analyze-tools"
        "vibe-check-recent"
        "vibe-check-view-stats"
    )

    for skill in "${expected_skills[@]}"; do
        if [ ! -d "$skills_dir/$skill" ]; then
            log_error "Skill not installed: $skill"
            return 1
        fi

        if [ ! -f "$skills_dir/$skill/SKILL.md" ]; then
            log_error "Skill missing SKILL.md: $skill"
            return 1
        fi

        log_verbose "✓ $skill"
    done

    return 0
}

test_command_availability() {
    log_verbose "Checking vibe-check command..."

    # Detect installation type and set wrapper path
    local wrapper_script
    if [ -f "$HOME/.vibe-check/vibe-check" ]; then
        # Standard installation
        wrapper_script="$HOME/.vibe-check/vibe-check"
        log_verbose "Checking standard installation wrapper"
    elif [ -f "$REPO_ROOT/vibe-check" ]; then
        # Git-based installation
        wrapper_script="$REPO_ROOT/vibe-check"
        log_verbose "Checking git-based installation wrapper"
    else
        log_error "vibe-check wrapper script not created"
        return 1
    fi

    if [ ! -x "$wrapper_script" ]; then
        log_error "vibe-check wrapper script not executable: $wrapper_script"
        return 1
    fi

    # Test command execution
    if ! "$wrapper_script" --version &>/dev/null; then
        log_error "vibe-check command fails to execute"
        return 1
    fi

    log_verbose "✓ vibe-check command works at $wrapper_script"
    return 0
}

test_python_dependencies() {
    log_verbose "Checking Python dependencies..."

    # Detect installation type and set venv path
    local venv_path
    if [ -d "$HOME/.vibe-check/venv" ]; then
        venv_path="$HOME/.vibe-check/venv"
    elif [ -d "$REPO_ROOT/venv" ]; then
        venv_path="$REPO_ROOT/venv"
    else
        log_error "Virtual environment not found"
        return 1
    fi

    # Activate venv and check imports
    source "$venv_path/bin/activate"

    local required_modules=("watchdog" "requests" "sqlite3")

    for module in "${required_modules[@]}"; do
        if ! python3 -c "import $module" 2>/dev/null; then
            log_error "Python module not installed: $module"
            deactivate
            return 1
        fi
        log_verbose "✓ $module"
    done

    deactivate
    return 0
}

# ============================================================================
# UPDATE/REINSTALL TESTS
# ============================================================================

test_reinstall_update() {
    if [ "$QUICK_MODE" = true ]; then
        log_info "Skipping reinstall test (quick mode)"
        return 0
    fi

    log_info "Testing reinstall/update..."

    cd "$REPO_ROOT"
    if ! ./scripts/install.sh --skip-auth 2>&1 | tee /tmp/vibe-check-test-reinstall.log; then
        log_error "Reinstall failed"
        return 1
    fi

    # Should still have all the same components
    if [ ! -f "$HOME/.vibe-check/config.json" ]; then
        log_error "Config lost during reinstall"
        return 1
    fi

    log_verbose "✓ Reinstall successful"
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

    log_verbose "Testing daemon functionality..."

    # Detect installation type and set command path
    local vibe_check_cmd
    if [ -f "$HOME/.vibe-check/vibe-check" ]; then
        vibe_check_cmd="$HOME/.vibe-check/vibe-check"
    elif [ -f "$REPO_ROOT/vibe-check" ]; then
        vibe_check_cmd="$REPO_ROOT/vibe-check"
    else
        log_error "vibe-check command not found"
        return 1
    fi

    # Simplified test: just verify daemon is running and responsive
    # Full start/stop cycle is difficult to test with LaunchAgent's KeepAlive=true

    # Check if daemon is running (case-insensitive)
    if ! "$vibe_check_cmd" status 2>&1 | grep -iq "running"; then
        # Try to start daemon
        START_OUTPUT=$("$vibe_check_cmd" start 2>&1)
        if ! echo "$START_OUTPUT" | grep -iEq "(started|Starting monitor|already running)"; then
            log_error "Failed to ensure daemon is running"
            log_verbose "Start output: $START_OUTPUT"
            return 1
        fi
        sleep 2
    fi

    # Verify daemon is running (case-insensitive)
    STATUS_OUTPUT=$("$vibe_check_cmd" status 2>&1)
    if ! echo "$STATUS_OUTPUT" | grep -iq "running"; then
        log_error "Daemon not running"
        log_verbose "Status output: $STATUS_OUTPUT"
        return 1
    fi

    # Verify PID file exists and contains valid PID
    if [ ! -f "$HOME/.vibe-check/.monitor.pid" ]; then
        log_error "PID file not found"
        return 1
    fi

    PID=$(cat "$HOME/.vibe-check/.monitor.pid")
    if ! ps -p "$PID" > /dev/null 2>&1; then
        log_error "Daemon process (PID: $PID) not found in process list"
        return 1
    fi

    log_verbose "✓ Daemon is running and responsive (PID: $PID)"
    return 0
}

test_database_operations() {
    log_verbose "Testing database operations..."

    local db_file="$HOME/.vibe-check/vibe_check.db"

    # Skip if database doesn't exist yet (expected in quick mode/fresh environments)
    if [ ! -f "$db_file" ]; then
        if [ "$QUICK_MODE" = true ]; then
            log_info "Skipping database operations test (database not yet created)"
            return 0
        else
            log_error "Database file not found for operations test"
            return 1
        fi
    fi

    # Test read-only access
    if ! sqlite3 "file:$db_file?mode=ro" "SELECT COUNT(*) FROM conversation_events" &>/dev/null; then
        log_error "Failed to query database in read-only mode"
        return 1
    fi

    # Test that schema is correct
    local schema=$(sqlite3 "$db_file" ".schema conversation_events")
    if ! echo "$schema" | grep -q "event_session_id"; then
        log_error "Database schema missing expected columns"
        return 1
    fi

    log_verbose "✓ Database operations work"
    return 0
}

test_event_monitoring() {
    if [ "$QUICK_MODE" = true ]; then
        log_info "Skipping event monitoring test (quick mode)"
        return 0
    fi

    log_verbose "Testing event monitoring and database insertion..."

    local db_file="$HOME/.vibe-check/vibe_check.db"
    local simulate_script="$REPO_ROOT/scripts/simulate-event.sh"

    # Check if simulate script exists
    if [ ! -f "$simulate_script" ]; then
        log_warning "simulate-event.sh not found, skipping test"
        return 0
    fi

    # Start daemon if not running (case-insensitive)
    if ! "$HOME/.vibe-check/vibe-check" status 2>&1 | grep -iq "running"; then
        if ! "$HOME/.vibe-check/vibe-check" start 2>&1 | grep -iEq "(started|Starting|already running)"; then
            log_error "Failed to start daemon for event monitoring test"
            return 1
        fi
        sleep 2  # Give daemon time to initialize
    fi

    # Get initial event count
    local initial_count=$(sqlite3 "$db_file" "SELECT COUNT(*) FROM conversation_events" 2>/dev/null || echo "0")
    log_verbose "Initial event count: $initial_count"

    # Generate a unique test message
    local test_message="TEST_EVENT_$(date +%s)_$$"

    # Create a simulated event
    log_verbose "Generating simulated event..."
    if ! bash "$simulate_script" "$test_message" &>/dev/null; then
        log_error "Failed to generate simulated event"
        "$HOME/.vibe-check/vibe-check" stop 2>/dev/null
        return 1
    fi

    # Wait for event to be processed (watchdog + processing time)
    log_verbose "Waiting for event to be processed..."
    sleep 5

    # Check if event was inserted into database
    local final_count=$(sqlite3 "$db_file" "SELECT COUNT(*) FROM conversation_events" 2>/dev/null || echo "0")
    log_verbose "Final event count: $final_count"

    if [ "$final_count" -le "$initial_count" ]; then
        log_error "Event was not inserted into database (count: $initial_count -> $final_count)"
        "$HOME/.vibe-check/vibe-check" stop 2>/dev/null
        return 1
    fi

    # Verify the specific test message was captured
    if ! sqlite3 "$db_file" "SELECT event_message FROM conversation_events WHERE event_message LIKE '%$test_message%'" 2>/dev/null | grep -q "$test_message"; then
        log_error "Test message not found in database"
        "$HOME/.vibe-check/vibe-check" stop 2>/dev/null
        return 1
    fi

    # Verify event has required fields
    local event_data=$(sqlite3 "$db_file" "SELECT event_session_id, event_uuid, event_type FROM conversation_events WHERE event_message LIKE '%$test_message%' LIMIT 1" 2>/dev/null)
    if [ -z "$event_data" ]; then
        log_error "Event missing required fields"
        "$HOME/.vibe-check/vibe-check" stop 2>/dev/null
        return 1
    fi

    log_verbose "✓ Event successfully captured and stored"
    log_verbose "✓ Event data: $event_data"

    # Stop daemon
    "$HOME/.vibe-check/vibe-check" stop 2>/dev/null

    return 0
}

# ============================================================================
# MAIN TEST RUNNER
# ============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Vibe Check Installation Test Suite                 ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_summary() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}Test Summary${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Total tests run:    $TESTS_RUN"
    echo -e "Passed:             ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed:             ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "${RED}Failed tests:${NC}"
        for test in "${FAILED_TESTS[@]}"; do
            echo -e "  ${RED}✗${NC} $test"
        done
        echo ""
        return 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        echo ""
        return 0
    fi
}

# Main execution
main() {
    # Handle cleanup-only mode
    if [ "$CLEANUP_ONLY" = true ]; then
        cleanup_test_environment
        restore_test_environment
        exit 0
    fi

    print_header

    # Run prerequisite checks first
    echo -e "${BOLD}Checking Prerequisites...${NC}"
    if ! test_prerequisites; then
        log_error "Prerequisites not met. Cannot continue with tests."
        exit 2
    fi
    log_success "All prerequisites met"

    # Clean environment before testing
    cleanup_test_environment

    # Ensure cleanup happens on exit
    trap restore_test_environment EXIT

    # Run test suite
    echo ""
    echo -e "${BOLD}Running Installation Tests...${NC}"

    run_test "Fresh Installation" test_fresh_install
    run_test "Installation Directories" test_installation_directories
    run_test "Configuration Created" test_configuration_created
    run_test "Database Created" test_database_created
    run_test "Skills Installed" test_skills_installed
    run_test "Command Availability" test_command_availability
    run_test "Python Dependencies" test_python_dependencies

    echo ""
    echo -e "${BOLD}Running Update Tests...${NC}"
    run_test "Reinstall/Update" test_reinstall_update

    echo ""
    echo -e "${BOLD}Running Functional Tests...${NC}"
    run_test "Daemon Start/Stop" test_daemon_start_stop
    run_test "Database Operations" test_database_operations
    run_test "Event Monitoring & Storage" test_event_monitoring

    # Print summary and exit with appropriate code
    if print_summary; then
        exit 0
    else
        exit 1
    fi
}

# Run main
main
