#!/bin/bash
set -e  # Exit on error

# VibeCheck - Build Release .app Bundle
# Creates a signed macOS .app bundle ready for distribution

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/apple/Products/Release"
APP_NAME="VibeCheck"
APP_BUNDLE="$PROJECT_DIR/dist/$APP_NAME.app"
BUNDLE_ID="com.wanderingstan.vibe-check"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔨 Building VibeCheck Release...${NC}"

# Clean previous build
echo "Cleaning previous builds..."
rm -rf "$PROJECT_DIR/dist"
rm -rf "$PROJECT_DIR/.build/release"
rm -rf "$PROJECT_DIR/.build/apple"

# Build release binary with Swift Package Manager
echo -e "${BLUE}Building release binary...${NC}"
cd "$PROJECT_DIR"
swift build -c release

# Create .app bundle structure
echo -e "${BLUE}Creating .app bundle structure...${NC}"
mkdir -p "$PROJECT_DIR/dist"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
echo "Copying binary..."
cp "$PROJECT_DIR/.build/release/VibeCheck" "$APP_BUNDLE/Contents/MacOS/VibeCheck"
chmod +x "$APP_BUNDLE/Contents/MacOS/VibeCheck"

# Copy Info.plist
echo "Copying Info.plist..."
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy skills
echo "Copying skills..."
if [ -d "$PROJECT_DIR/skills" ]; then
    cp -R "$PROJECT_DIR/skills" "$APP_BUNDLE/Contents/Resources/skills"
    echo -e "${GREEN}✓ Copied $(find "$APP_BUNDLE/Contents/Resources/skills" -maxdepth 1 -type d | wc -l | xargs) skills${NC}"
else
    echo -e "${YELLOW}⚠️  Skills directory not found at $PROJECT_DIR/skills${NC}"
fi

# Code signing
echo -e "${BLUE}Code signing...${NC}"

# Check for signing identity
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "Found Developer ID certificate, signing with it..."
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -n1 | sed -n 's/.*"\(.*\)".*/\1/p')
    echo "Using identity: $SIGN_IDENTITY"

    codesign --force --options runtime \
        --entitlements "$PROJECT_DIR/VibeCheck.entitlements" \
        --sign "$SIGN_IDENTITY" \
        --timestamp \
        --deep \
        "$APP_BUNDLE"

    echo -e "${GREEN}✓ Signed with Developer ID (ready for notarization)${NC}"
else
    echo -e "${YELLOW}No Developer ID certificate found, using ad-hoc signature${NC}"
    echo "(For distribution, you'll need to sign with a Developer ID)"

    codesign --force --options runtime \
        --entitlements "$PROJECT_DIR/VibeCheck.entitlements" \
        --sign - \
        --deep \
        "$APP_BUNDLE"

    echo -e "${YELLOW}✓ Signed with ad-hoc signature (local testing only)${NC}"
fi

# Verify code signature
echo -e "${BLUE}Verifying code signature...${NC}"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
echo -e "${GREEN}✓ Code signature verified${NC}"

# Display bundle info
echo ""
echo -e "${GREEN}✅ Build complete!${NC}"
echo ""
echo "App bundle: $APP_BUNDLE"
echo "Bundle ID: $BUNDLE_ID"
echo "Version: $(defaults read "$APP_BUNDLE/Contents/Info.plist" CFBundleShortVersionString)"
echo "Min macOS: $(defaults read "$APP_BUNDLE/Contents/Info.plist" LSMinimumSystemVersion)"
echo ""

# Display size
APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo "Bundle size: $APP_SIZE"
echo ""

# Test launch (optional)
read -p "Test launch the app? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Launching $APP_NAME..."
    open "$APP_BUNDLE"
fi

echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "1. Test the app: open $APP_BUNDLE"
echo "2. Create DMG: ./Scripts/create-dmg.sh"
echo "3. (Optional) Notarize: xcrun notarytool submit ..."
