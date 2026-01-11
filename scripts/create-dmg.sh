#!/bin/bash
set -e

# TypeTalk DMG Creation Script
# This script creates a DMG installer for TypeTalk

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION=$(cat "$PROJECT_DIR/VERSION")
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="TypeTalk"
DMG_NAME="$APP_NAME-$VERSION.dmg"

echo "Creating DMG for $APP_NAME v$VERSION..."

# Check if create-dmg is installed
if ! command -v create-dmg &> /dev/null; then
    echo "Error: create-dmg is not installed."
    echo "Install with: brew install create-dmg"
    exit 1
fi

# Check if app exists
if [ ! -d "$BUILD_DIR/$APP_NAME.app" ]; then
    echo "Error: $BUILD_DIR/$APP_NAME.app not found."
    echo "Run ./scripts/build.sh first."
    exit 1
fi

# Remove existing DMG if it exists
rm -f "$PROJECT_DIR/$DMG_NAME"

# Create DMG
echo "Creating DMG..."

# Build create-dmg arguments
DMG_ARGS=(
    --volname "$APP_NAME"
    --window-pos 200 120
    --window-size 600 400
    --icon-size 100
    --icon "$APP_NAME.app" 150 190
    --hide-extension "$APP_NAME.app"
    --app-drop-link 450 185
    --no-internet-enable
)

# Add volume icon if it exists
ICON_PATH="$BUILD_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns"
if [ -f "$ICON_PATH" ]; then
    DMG_ARGS+=(--volicon "$ICON_PATH")
    echo "Using app icon for volume icon"
else
    echo "Note: AppIcon.icns not found, creating DMG without volume icon"
fi

create-dmg \
    "${DMG_ARGS[@]}" \
    "$PROJECT_DIR/$DMG_NAME" \
    "$BUILD_DIR/$APP_NAME.app" \
    || true  # create-dmg returns non-zero on some warnings

# Verify DMG was created
if [ -f "$PROJECT_DIR/$DMG_NAME" ]; then
    echo "DMG created successfully: $PROJECT_DIR/$DMG_NAME"

    # Show file size
    SIZE=$(du -h "$PROJECT_DIR/$DMG_NAME" | cut -f1)
    echo "Size: $SIZE"
else
    echo "Error: DMG creation failed"
    exit 1
fi

echo "DMG creation complete!"
