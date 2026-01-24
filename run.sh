#!/bin/bash
set -e

cd "$(dirname "$0")"

# Kill existing instance
pkill -9 Axel 2>/dev/null || true

# Build
echo "Building..."
xcodebuild -project Axel.xcodeproj -scheme Axel -destination 'platform=macOS' -configuration Debug build -quiet

# Find and launch the built app
APP_PATH=$(xcodebuild -project Axel.xcodeproj -scheme Axel -destination 'platform=macOS' -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 "BUILT_PRODUCTS_DIR" | awk '{print $3}')
echo "Launching..."
open "$APP_PATH/Axel.app"
