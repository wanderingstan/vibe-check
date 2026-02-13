#!/bin/bash
#
# Quick Test - Fast validation for pre-commit checks
#
# This runs a minimal set of tests to catch obvious issues before committing.
# For full testing, use test-install.sh
#
# Usage:
#   ./quick-test.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

echo -e "${BLUE}Running quick validation tests...${NC}"

# Test 1: Python syntax check
echo -n "Checking Python syntax... "
if python3 -m py_compile "$REPO_ROOT/vibe-check.py" 2>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Syntax error in vibe-check.py${NC}"
    exit 1
fi

# Test 2: Required files exist
echo -n "Checking required files... "
required_files=(
    "vibe-check.py"
    "requirements.txt"
    "scripts/install.sh"
    "README.md"
)

for file in "${required_files[@]}"; do
    if [ ! -f "$REPO_ROOT/$file" ]; then
        echo -e "${RED}✗ Missing: $file${NC}"
        exit 1
    fi
done
echo -e "${GREEN}✓${NC}"

# Test 3: Shell script syntax
echo -n "Checking shell scripts... "
for script in "$REPO_ROOT"/scripts/*.sh; do
    if [ -f "$script" ]; then
        if ! bash -n "$script" 2>/dev/null; then
            echo -e "${RED}✗ Syntax error in $(basename "$script")${NC}"
            exit 1
        fi
    fi
done
echo -e "${GREEN}✓${NC}"

# Test 4: JSON files are valid
echo -n "Checking JSON files... "
if [ -f "$REPO_ROOT/config.json.example" ]; then
    if ! python3 -c "import json; json.load(open('$REPO_ROOT/config.json.example'))" 2>/dev/null; then
        echo -e "${RED}✗ Invalid JSON in config.json.example${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}✓${NC}"

# Test 5: Skills have required files
echo -n "Checking skills... "
if [ -d "$REPO_ROOT/skills" ]; then
    for skill_dir in "$REPO_ROOT"/skills/vibe-check-*; do
        if [ -d "$skill_dir" ]; then
            if [ ! -f "$skill_dir/SKILL.md" ]; then
                echo -e "${RED}✗ Missing SKILL.md in $(basename "$skill_dir")${NC}"
                exit 1
            fi
        fi
    done
fi
echo -e "${GREEN}✓${NC}"

# Test 6: Version consistency
echo -n "Checking version consistency... "
py_version=$(grep '^VERSION = ' "$REPO_ROOT/vibe-check.py" | cut -d'"' -f2)
if [ -z "$py_version" ]; then
    echo -e "${RED}✗ Cannot find version in vibe-check.py${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} (v$py_version)"

echo ""
echo -e "${GREEN}All quick tests passed!${NC}"
echo ""
echo "Run './tests/test-install.sh' for comprehensive testing."
