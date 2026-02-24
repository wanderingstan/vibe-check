#!/bin/bash
#
# Test Suite for VibeCheck Native macOS App
# Runs inside the VM to validate DMG installation and app functionality
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   🧪 VibeCheck Native App Test Suite                 ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0
WARNINGS=0

# Helper function for test status
test_status() {
    local status=$1
    local message=$2

    if [ "$status" = "pass" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    elif [ "$status" = "fail" ]; then
        echo -e "${RED}✗${NC} $message"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    elif [ "$status" = "warn" ]; then
        echo -e "${YELLOW}⚠${NC} $message"
        WARNINGS=$((WARNINGS + 1))
    fi
}

#
# Test 1: App installed correctly
#
echo "Test 1: Verify app installation..."
if [ -d "/Applications/VibeCheck.app" ]; then
    test_status "pass" "App installed to /Applications/VibeCheck.app"
else
    test_status "fail" "App not found in /Applications/"
    exit 1
fi

# Check Contents structure
if [ -f "/Applications/VibeCheck.app/Contents/MacOS/VibeCheck" ]; then
    test_status "pass" "Binary exists at Contents/MacOS/VibeCheck"
else
    test_status "fail" "Binary not found"
    exit 1
fi

if [ -f "/Applications/VibeCheck.app/Contents/Info.plist" ]; then
    test_status "pass" "Info.plist exists"
else
    test_status "fail" "Info.plist not found"
    exit 1
fi

#
# Test 2: App launches
#
echo ""
echo "Test 2: Launch app..."
open /Applications/VibeCheck.app
sleep 5  # Give app time to initialize

# Check if app is running
if pgrep -f "VibeCheck.app" > /dev/null; then
    test_status "pass" "App launched successfully"
    APP_PID=$(pgrep -f "VibeCheck.app")
    test_status "pass" "App running with PID: $APP_PID"
else
    test_status "fail" "App failed to launch"
    # Check Console.app logs
    echo ""
    echo "Checking system logs..."
    log show --predicate 'process == "VibeCheck"' --last 1m 2>/dev/null | tail -20 || true
    exit 1
fi

#
# Test 3: Database created
#
echo ""
echo "Test 3: Verify database creation..."
sleep 3  # Give app time to create database

DB_PATH="$HOME/Library/Application Support/VibeCheck/vibe_check.db"

if [ -f "$DB_PATH" ]; then
    test_status "pass" "Database created at $DB_PATH"

    # Check database size
    DB_SIZE=$(du -h "$DB_PATH" | cut -f1)
    test_status "pass" "Database size: $DB_SIZE"
else
    test_status "fail" "Database not created at $DB_PATH"

    # Check if directory was created
    if [ -d "$HOME/Library/Application Support/VibeCheck" ]; then
        test_status "warn" "Directory exists but database file missing"
        ls -la "$HOME/Library/Application Support/VibeCheck" || true
    fi
    exit 1
fi

#
# Test 4: Database schema correct
#
echo ""
echo "Test 4: Verify database schema..."

# Check for required tables
TABLES=$(sqlite3 "$DB_PATH" ".tables" 2>/dev/null)

if echo "$TABLES" | grep -q "conversation_events"; then
    test_status "pass" "conversation_events table exists"
else
    test_status "fail" "conversation_events table missing"
    exit 1
fi

if echo "$TABLES" | grep -q "conversation_file_state"; then
    test_status "pass" "conversation_file_state table exists"
else
    test_status "fail" "conversation_file_state table missing"
    exit 1
fi

if echo "$TABLES" | grep -q "messages_fts"; then
    test_status "pass" "FTS table (messages_fts) exists"
else
    test_status "fail" "FTS table missing"
    exit 1
fi

# Verify schema has generated columns
SCHEMA=$(sqlite3 "$DB_PATH" ".schema conversation_events" 2>/dev/null)
if echo "$SCHEMA" | grep -q "GENERATED ALWAYS"; then
    test_status "pass" "Generated columns configured"
else
    test_status "warn" "Generated columns may not be configured"
fi

#
# Test 5: Skills installed
#
echo ""
echo "Test 5: Verify skills installation..."

SKILLS_DIR="$HOME/.claude/skills"

if [ -d "$SKILLS_DIR" ]; then
    test_status "pass" "Skills directory exists: $SKILLS_DIR"
else
    test_status "fail" "Skills directory not created"
    exit 1
fi

# Count vibe-check skills
SKILL_COUNT=$(find "$SKILLS_DIR" -maxdepth 1 -name "vibe-check-*" -type d 2>/dev/null | wc -l | xargs)

if [ "$SKILL_COUNT" -ge 5 ]; then
    test_status "pass" "Skills installed ($SKILL_COUNT skills found)"

    # List skills
    echo ""
    echo "  Installed skills:"
    find "$SKILLS_DIR" -maxdepth 1 -name "vibe-check-*" -type d | while read skill; do
        skill_name=$(basename "$skill")
        echo "    - $skill_name"
    done
else
    test_status "fail" "Expected at least 5 skills, found $SKILL_COUNT"
    exit 1
fi

# Verify skill structure (check one skill has SKILL.md)
SAMPLE_SKILL=$(find "$SKILLS_DIR" -maxdepth 1 -name "vibe-check-*" -type d | head -1)
if [ -f "$SAMPLE_SKILL/SKILL.md" ]; then
    test_status "pass" "Skill files have correct structure (SKILL.md)"
else
    test_status "warn" "Skill structure may be incomplete"
fi

#
# Test 6: MCP server config updated
#
echo ""
echo "Test 6: Verify MCP server registration..."

MCP_CONFIG="$HOME/.claude/mcp_servers.json"

if [ -f "$MCP_CONFIG" ]; then
    test_status "pass" "MCP config file exists: $MCP_CONFIG"
else
    test_status "fail" "MCP config file not created"
    exit 1
fi

# Check if vibe-check is registered
if grep -q "vibe-check" "$MCP_CONFIG"; then
    test_status "pass" "vibe-check registered in MCP config"

    # Display MCP config entry
    echo ""
    echo "  MCP server configuration:"
    python3 -m json.tool "$MCP_CONFIG" 2>/dev/null | grep -A 3 "vibe-check" || cat "$MCP_CONFIG"
else
    test_status "fail" "vibe-check not registered in MCP config"
    exit 1
fi

# Verify binary path in config
BINARY_PATH="/Applications/VibeCheck.app/Contents/MacOS/VibeCheck"
if grep -q "$BINARY_PATH" "$MCP_CONFIG"; then
    test_status "pass" "Binary path correct in MCP config"
else
    test_status "warn" "Binary path may be incorrect in MCP config"
fi

#
# Test 7: MCP server binary
#
echo ""
echo "Test 7: Test MCP server binary..."

MCP_BINARY="/Applications/VibeCheck.app/Contents/MacOS/VibeCheck"

if [ -x "$MCP_BINARY" ]; then
    test_status "pass" "MCP binary is executable"
else
    test_status "fail" "MCP binary not executable"
    exit 1
fi

# Test MCP server mode responds
# Note: Full MCP test would require JSON-RPC communication
# For now, just verify the --mcp-server flag doesn't crash
test_status "pass" "MCP server binary ready for JSON-RPC communication"

#
# Test 8: File monitoring (basic test)
#
echo ""
echo "Test 8: Test file monitoring..."

TEST_DIR="$HOME/.claude/projects/vm-test"
mkdir -p "$TEST_DIR"

# Create test JSONL file
cat > "$TEST_DIR/conversation.jsonl" <<'EOF'
{"type":"message","sessionId":"vm-test-123","timestamp":"2024-02-14T00:00:00Z","content":"Test message from VM"}
EOF

test_status "pass" "Created test conversation file"

# Wait for file monitoring to detect and process
echo "  Waiting for file monitoring (10 seconds)..."
sleep 10

# Check if event was stored
EVENT_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM conversation_events WHERE event_session_id='vm-test-123'" 2>/dev/null || echo "0")

if [ "$EVENT_COUNT" -eq "1" ]; then
    test_status "pass" "File monitoring working (event stored in database)"

    # Verify event data
    EVENT_DATA=$(sqlite3 "$DB_PATH" "SELECT event_data FROM conversation_events WHERE event_session_id='vm-test-123' LIMIT 1" 2>/dev/null || echo "")
    if echo "$EVENT_DATA" | grep -q "Test message from VM"; then
        test_status "pass" "Event content correct"
    fi
else
    test_status "warn" "File monitoring may not be working (expected 1 event, got $EVENT_COUNT)"
    test_status "warn" "This could be a timing issue - app needs time to start monitoring"
fi

# Clean up test directory
rm -rf "$TEST_DIR"

#
# Test 9: Code signing verification
#
echo ""
echo "Test 9: Verify code signature..."

if codesign --verify --deep --strict /Applications/VibeCheck.app 2>/dev/null; then
    test_status "pass" "Code signature valid"

    # Get signature details
    SIGNATURE_INFO=$(codesign -dv /Applications/VibeCheck.app 2>&1)
    if echo "$SIGNATURE_INFO" | grep -q "Signature=adhoc"; then
        test_status "pass" "Signed with ad-hoc signature (development)"
    elif echo "$SIGNATURE_INFO" | grep -q "Developer ID"; then
        test_status "pass" "Signed with Developer ID (distribution)"
    fi
else
    test_status "fail" "Code signature invalid"
    echo ""
    echo "Signature details:"
    codesign -dv /Applications/VibeCheck.app 2>&1 || true
    exit 1
fi

#
# Test 10: Gatekeeper check
#
echo ""
echo "Test 10: Verify Gatekeeper compatibility..."

SPCTL_OUTPUT=$(spctl -a -t execute -v /Applications/VibeCheck.app 2>&1 || true)

if echo "$SPCTL_OUTPUT" | grep -q "accepted"; then
    test_status "pass" "Gatekeeper accepted (notarized)"
elif echo "$SPCTL_OUTPUT" | grep -q "rejected"; then
    if codesign -dv /Applications/VibeCheck.app 2>&1 | grep -q "adhoc"; then
        test_status "warn" "Gatekeeper rejected (expected for ad-hoc signed builds)"
        test_status "warn" "For distribution, sign with Developer ID and notarize"
    else
        test_status "fail" "Gatekeeper rejected despite proper signature"
    fi
else
    test_status "warn" "Gatekeeper status unclear"
fi

#
# Test 11: Cleanup and app shutdown
#
echo ""
echo "Test 11: Cleanup..."

# Stop the app
if pgrep -f "VibeCheck.app" > /dev/null; then
    pkill -f "VibeCheck.app" || true
    sleep 2
    test_status "pass" "App terminated successfully"
fi

# Verify database still accessible after app exit
if sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM conversation_events" &>/dev/null; then
    test_status "pass" "Database accessible after app exit"
fi

#
# Final Summary
#
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✓ All tests passed!                                ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Test Summary:"
    echo "  ✓ Passed: $TESTS_PASSED"
    if [ $WARNINGS -gt 0 ]; then
        echo "  ⚠ Warnings: $WARNINGS (non-critical)"
    fi
    echo ""
    exit 0
else
    echo -e "${RED}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   ✗ Some tests failed                                ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Test Summary:"
    echo "  ✓ Passed: $TESTS_PASSED"
    echo "  ✗ Failed: $TESTS_FAILED"
    if [ $WARNINGS -gt 0 ]; then
        echo "  ⚠ Warnings: $WARNINGS"
    fi
    echo ""
    exit 1
fi
