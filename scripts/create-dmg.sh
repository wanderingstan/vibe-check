#!/bin/bash
set -e  # Exit on error

# VibeCheck - Create DMG for Distribution
# Creates a DMG installer with drag-to-Applications setup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="VibeCheck"
APP_BUNDLE="$PROJECT_DIR/dist/$APP_NAME.app"
DMG_NAME="VibeCheck-2.0.0"
DMG_PATH="$PROJECT_DIR/dist/$DMG_NAME.dmg"
TEMP_DMG="$PROJECT_DIR/dist/temp.dmg"
VOLUME_NAME="VibeCheck Installer"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}📦 Creating DMG for VibeCheck...${NC}"

# Check if .app bundle exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo -e "${RED}❌ Error: $APP_BUNDLE not found${NC}"
    echo "Run ./Scripts/build-release.sh first"
    exit 1
fi

# Clean previous DMG
rm -f "$DMG_PATH"
rm -f "$TEMP_DMG"

# Check if create-dmg tool is available (Homebrew: brew install create-dmg)
if command -v create-dmg &> /dev/null; then
    echo -e "${BLUE}Using create-dmg tool...${NC}"

    # Build create-dmg command with optional icon
    CMD=(create-dmg
        --volname "$VOLUME_NAME"
        --window-pos 200 120
        --window-size 600 400
        --icon-size 100
        --icon "$APP_NAME.app" 175 190
        --hide-extension "$APP_NAME.app"
        --app-drop-link 425 190
        --no-internet-enable)

    # Add volume icon if it exists
    if [ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]; then
        CMD+=(--volicon "$APP_BUNDLE/Contents/Resources/AppIcon.icns")
    fi

    # Execute create-dmg
    "${CMD[@]}" "$DMG_PATH" "$APP_BUNDLE"

    echo -e "${GREEN}✅ DMG created with create-dmg${NC}"

else
    echo -e "${YELLOW}create-dmg not found, using hdiutil (basic DMG)${NC}"
    echo "For better DMG: brew install create-dmg"

    # Create temporary directory for DMG contents
    TEMP_DIR="$PROJECT_DIR/dist/dmg-temp"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    # Copy app to temp directory
    cp -R "$APP_BUNDLE" "$TEMP_DIR/"

    # Create symlink to Applications
    ln -s /Applications "$TEMP_DIR/Applications"

    # Create DMG
    hdiutil create -volname "$VOLUME_NAME" \
        -srcfolder "$TEMP_DIR" \
        -ov \
        -format UDZO \
        "$TEMP_DMG"

    # Convert to final DMG
    mv "$TEMP_DMG" "$DMG_PATH"

    # Clean up temp directory
    rm -rf "$TEMP_DIR"

    echo -e "${GREEN}✅ Basic DMG created with hdiutil${NC}"
fi

# Display DMG info
echo ""
echo -e "${GREEN}✅ DMG Created!${NC}"
echo ""
echo "DMG: $DMG_PATH"
DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
echo "Size: $DMG_SIZE"
echo ""

# Verify DMG
echo -e "${BLUE}Verifying DMG...${NC}"
if hdiutil verify "$DMG_PATH"; then
    echo -e "${GREEN}✓ DMG verified successfully${NC}"
else
    echo -e "${RED}❌ DMG verification failed${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "1. Test the DMG: open $DMG_PATH"
echo "2. Distribute: Upload to GitHub Releases or your website"
echo "3. (Optional) Notarize for Gatekeeper:"
echo "   xcrun notarytool submit $DMG_PATH --keychain-profile \"YOUR_PROFILE\" --wait"
echo "   xcrun stapler staple $DMG_PATH"
