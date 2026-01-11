#!/bin/bash
set -e

# TypeTalk Build Script
# This script builds the TypeTalk app for release

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION=$(cat "$PROJECT_DIR/VERSION")
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="TypeTalk"

echo "Building $APP_NAME v$VERSION..."

# Clean build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Check if xcodegen is installed
if command -v xcodegen &> /dev/null; then
    echo "Generating Xcode project with XcodeGen..."
    cd "$PROJECT_DIR"
    xcodegen generate
else
    echo "XcodeGen not found, using existing project..."
fi

# Check if xcodeproj exists
if [ ! -d "$PROJECT_DIR/$APP_NAME.xcodeproj" ]; then
    echo "Error: $APP_NAME.xcodeproj not found. Please run 'xcodegen generate' first."
    exit 1
fi

# Build the app
echo "Building release version..."
xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
    archive

# Export the app
echo "Exporting app bundle..."
xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
    -exportPath "$BUILD_DIR" \
    -exportOptionsPlist "$PROJECT_DIR/ExportOptions.plist"

# Verify the app exists
if [ -d "$BUILD_DIR/$APP_NAME.app" ]; then
    echo "Build successful: $BUILD_DIR/$APP_NAME.app"
else
    echo "Error: App bundle not found after export"
    exit 1
fi

echo "Build complete!"
