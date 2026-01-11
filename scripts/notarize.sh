#!/bin/bash
set -e

# TypeTalk Notarization Script
# This script notarizes the DMG for distribution
#
# Required environment variables:
#   APPLE_ID       - Your Apple ID email
#   TEAM_ID        - Your Apple Developer Team ID
#   APP_PASSWORD   - App-specific password for notarization

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION=$(cat "$PROJECT_DIR/VERSION")
APP_NAME="TypeTalk"
DMG_FILE="$PROJECT_DIR/$APP_NAME-$VERSION.dmg"

echo "Notarizing $APP_NAME v$VERSION..."

# Check environment variables
if [ -z "$APPLE_ID" ]; then
    echo "Error: APPLE_ID environment variable is not set"
    exit 1
fi

if [ -z "$TEAM_ID" ]; then
    echo "Error: TEAM_ID environment variable is not set"
    exit 1
fi

if [ -z "$APP_PASSWORD" ]; then
    echo "Error: APP_PASSWORD environment variable is not set"
    echo "Create an app-specific password at https://appleid.apple.com/"
    exit 1
fi

# Check if DMG exists
if [ ! -f "$DMG_FILE" ]; then
    echo "Error: $DMG_FILE not found."
    echo "Run ./scripts/create-dmg.sh first."
    exit 1
fi

# Submit for notarization
echo "Submitting for notarization..."
xcrun notarytool submit "$DMG_FILE" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    --wait

# Check notarization status
echo "Checking notarization status..."
SUBMISSION_ID=$(xcrun notarytool history \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    2>/dev/null | head -n 4 | tail -n 1 | awk '{print $1}')

if [ -n "$SUBMISSION_ID" ]; then
    xcrun notarytool log "$SUBMISSION_ID" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD"
fi

# Staple the notarization ticket
echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG_FILE"

# Verify stapling
echo "Verifying stapling..."
xcrun stapler validate "$DMG_FILE"

echo ""
echo "Notarization complete!"
echo "Notarized DMG: $DMG_FILE"
