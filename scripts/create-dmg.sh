#!/bin/bash
set -euo pipefail

# Create a professional DMG with drag-and-drop installer
# Usage: ./create-dmg.sh <app-path> <output-dmg-path>

APP_PATH="${1:?Usage: $0 <app-path> <output-dmg-path>}"
OUTPUT_DMG="${2:?Usage: $0 <app-path> <output-dmg-path>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

APP_NAME="$(basename "$APP_PATH" .app)"

# DMG window settings
WINDOW_WIDTH=600
WINDOW_HEIGHT=400
ICON_SIZE=128
APP_X=150
APP_Y=190
APPS_X=450
APPS_Y=190

# Background image path
BG_IMAGE="$SCRIPT_DIR/axel-background-dmg.png"

echo "Creating DMG for $APP_NAME..."

# Verify app exists
if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at $APP_PATH"
    exit 1
fi

# Find the app icon
APP_ICON=$(find "$APP_PATH/Contents/Resources" -name "*.icns" -print -quit 2>/dev/null)

# Verify background exists
if [ ! -f "$BG_IMAGE" ]; then
    echo "Error: Background image not found at $BG_IMAGE"
    exit 1
fi

# Remove existing DMG if present
rm -f "$OUTPUT_DMG"

# Create DMG using create-dmg
echo "Building DMG..."

CREATE_DMG_ARGS=(
    --volname "$APP_NAME"
    --window-pos 200 120
    --window-size "$WINDOW_WIDTH" "$WINDOW_HEIGHT"
    --icon-size "$ICON_SIZE"
    --icon "$APP_NAME.app" "$APP_X" "$APP_Y"
    --app-drop-link "$APPS_X" "$APPS_Y"
    --hide-extension "$APP_NAME.app"
    --background "$BG_IMAGE"
    --no-internet-enable
)

# Add volume icon if available
if [ -n "$APP_ICON" ] && [ -f "$APP_ICON" ]; then
    CREATE_DMG_ARGS+=(--volicon "$APP_ICON")
fi

create-dmg "${CREATE_DMG_ARGS[@]}" "$OUTPUT_DMG" "$APP_PATH" || true

# Verify DMG was created
if [ ! -f "$OUTPUT_DMG" ]; then
    echo "Error: Failed to create DMG"
    exit 1
fi

echo ""
echo "DMG created successfully: $OUTPUT_DMG"
ls -lh "$OUTPUT_DMG"
