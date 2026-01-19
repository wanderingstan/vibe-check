#!/bin/bash
# Simulate a new conversation event for testing vibe-check monitoring
# Creates a .jsonl file in the Claude Code conversations directory

# Configuration
PROJECTS_DIR="${HOME}/.claude/projects"
TEST_PROJECT_DIR="${PROJECTS_DIR}/-Users-wanderingstan-Developer-vibe-check"

# Generate a unique UUID
UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')

# Generate current timestamp in ISO format
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

# Message content (can be overridden via argument)
MESSAGE="${1:-TESTING vibe-check monitoring at $TIMESTAMP}"

# Create the test event JSON
EVENT=$(cat <<EOF
{"parentUuid":null,"isSidechain":false,"userType":"external","cwd":"/Users/wanderingstan/Developer/vibe-check","sessionId":"test-session-$UUID","version":"2.0.74","gitBranch":"main","type":"user","message":{"role":"user","content":[{"type":"text","text":"$MESSAGE"}]},"uuid":"$UUID","timestamp":"$TIMESTAMP"}
EOF
)

# Create the .jsonl file
OUTPUT_FILE="${TEST_PROJECT_DIR}/test-${UUID}.jsonl"

echo "$EVENT" > "$OUTPUT_FILE"

echo "✓ Created test event:"
echo "  File: $OUTPUT_FILE"
echo "  UUID: $UUID"
echo "  Timestamp: $TIMESTAMP"
echo "  Message: $MESSAGE"
