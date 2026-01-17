#!/bin/bash
#
# Release script for vibe-check Homebrew formula
# Creates a new version tag, updates the formula, and pushes to the tap
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TAP_DIR="/opt/homebrew/Library/Taps/wanderingstan/homebrew-vibe-check"
FORMULA_NAME="vibe-check"

cd "$PROJECT_DIR"

echo -e "${GREEN}🧜 Vibe-Check Homebrew Release Script${NC}"
echo "========================================"

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo -e "${YELLOW}Warning: You have uncommitted changes${NC}"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Get current version from latest tag
CURRENT_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
echo "Current version: $CURRENT_TAG"

# Parse version components
VERSION_REGEX="v([0-9]+)\.([0-9]+)\.([0-9]+)"
if [[ $CURRENT_TAG =~ $VERSION_REGEX ]]; then
    MAJOR="${BASH_REMATCH[1]}"
    MINOR="${BASH_REMATCH[2]}"
    PATCH="${BASH_REMATCH[3]}"
else
    echo -e "${RED}Error: Could not parse version from tag: $CURRENT_TAG${NC}"
    exit 1
fi

# Increment patch version by default
NEW_PATCH=$((PATCH + 1))
NEW_VERSION="v${MAJOR}.${MINOR}.${NEW_PATCH}"

# Allow override
if [ -n "$1" ]; then
    NEW_VERSION="$1"
    if [[ ! $NEW_VERSION =~ ^v ]]; then
        NEW_VERSION="v$NEW_VERSION"
    fi
fi

echo -e "New version: ${GREEN}$NEW_VERSION${NC}"
read -p "Create release $NEW_VERSION? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
fi

# Create and push tag
echo -e "\n${GREEN}Creating tag $NEW_VERSION...${NC}"
git tag "$NEW_VERSION"
git push origin main --tags

# Wait for GitHub to process the tag
echo "Waiting for GitHub to process tag..."
sleep 3

# Download tarball and calculate SHA256
TARBALL_URL="https://github.com/wanderingstan/vibe-check/archive/refs/tags/${NEW_VERSION}.tar.gz"
echo -e "\n${GREEN}Downloading tarball...${NC}"
TARBALL_PATH="/tmp/vibe-check-${NEW_VERSION}.tar.gz"
curl -L "$TARBALL_URL" -o "$TARBALL_PATH" 2>/dev/null

SHA256=$(shasum -a 256 "$TARBALL_PATH" | cut -d' ' -f1)
echo "SHA256: $SHA256"

# Update formula
echo -e "\n${GREEN}Updating formula...${NC}"
FORMULA_PATH="$PROJECT_DIR/vibe-check.rb"

# Update version in formula (only the main url and sha256, not resource blocks)
# Use awk to only update the sha256 that immediately follows the main url line
awk -v new_url="https://github.com/wanderingstan/vibe-check/archive/refs/tags/${NEW_VERSION}.tar.gz" \
    -v new_sha="${SHA256}" '
  /^  url "https:\/\/github.com\/wanderingstan\/vibe-check\/archive/ {
    print "  url \"" new_url "\""
    getline
    print "  sha256 \"" new_sha "\""
    next
  }
  { print }
' "$FORMULA_PATH" > "$FORMULA_PATH.tmp" && mv "$FORMULA_PATH.tmp" "$FORMULA_PATH"

# Copy to tap
echo -e "\n${GREEN}Updating tap repository...${NC}"
cp "$FORMULA_PATH" "$TAP_DIR/Formula/vibe-check.rb"

# Commit and push tap
cd "$TAP_DIR"
git add Formula/vibe-check.rb
git commit -m "Update to ${NEW_VERSION}"
git push

# Return to project dir
cd "$PROJECT_DIR"

# Commit formula update in main repo
git add vibe-check.rb
git commit -m "Update formula to ${NEW_VERSION}" || true  # May already be committed

echo -e "\n${GREEN}✅ Release $NEW_VERSION complete!${NC}"
echo ""
echo "To upgrade your local installation:"
echo "  brew upgrade vibe-check"
echo ""
echo "Or to reinstall from scratch:"
echo "  brew reinstall vibe-check"

# Ask if user wants to upgrade now
read -p "Upgrade now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "\n${GREEN}Upgrading...${NC}"
    brew upgrade vibe-check

    echo -e "\n${GREEN}Restarting service...${NC}"
    brew services restart vibe-check

    echo -e "\n${GREEN}Done! Checking status...${NC}"
    sleep 2
    vibe-check status
fi
