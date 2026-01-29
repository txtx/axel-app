#!/bin/bash
set -euo pipefail

# Test Sparkle update flow locally
# This script builds the app, creates a signed DMG, generates an appcast,
# and starts a local server to test the update mechanism.
#
# Prerequisites:
# 1. Add Sparkle package to Xcode project (File > Add Package Dependencies)
#    URL: https://github.com/sparkle-project/Sparkle
#    Version: 2.6.4 or latest
# 2. EdDSA keys generated (run: /tmp/sparkle/bin/generate_keys)
# 3. SUPublicEDKey added to Info.plist

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build-test"
DIST_DIR="$PROJECT_DIR/dist-test"
LOCAL_SERVER_PORT=8080

cd "$PROJECT_DIR"

echo "==================================="
echo "Sparkle Local Test"
echo "==================================="
echo ""

# Check for sign_update tool
if [ ! -f "$SCRIPT_DIR/sign_update" ]; then
    echo "Error: sign_update not found in scripts/"
    echo "Run: cp /tmp/sparkle/bin/sign_update scripts/"
    exit 1
fi

# Clean previous test builds
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# Step 1: Build version 1.0.0 (the "old" version users have)
echo ""
echo "Step 1: Building version 1.0.0 (old version)..."
echo "-----------------------------------"

xcodebuild \
    -scheme Axel \
    -project Axel.xcodeproj \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$BUILD_DIR/v1" \
    MARKETING_VERSION="1.0.0" \
    CURRENT_PROJECT_VERSION="1" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tail -20

cp -R "$BUILD_DIR/v1/Build/Products/Release/Axel.app" "$DIST_DIR/Axel-1.0.0.app"
echo "Built: $DIST_DIR/Axel-1.0.0.app"

# Step 2: Build version 1.1.0 (the "new" version to update to)
echo ""
echo "Step 2: Building version 1.1.0 (new version)..."
echo "-----------------------------------"

xcodebuild \
    -scheme Axel \
    -project Axel.xcodeproj \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$BUILD_DIR/v2" \
    MARKETING_VERSION="1.1.0" \
    CURRENT_PROJECT_VERSION="2" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tail -20

cp -R "$BUILD_DIR/v2/Build/Products/Release/Axel.app" "$DIST_DIR/Axel-1.1.0.app"
echo "Built: $DIST_DIR/Axel-1.1.0.app"

# Step 3: Create DMG for v1.1.0
echo ""
echo "Step 3: Creating DMG for version 1.1.0..."
echo "-----------------------------------"

"$SCRIPT_DIR/create-dmg.sh" "$DIST_DIR/Axel-1.1.0.app" "$DIST_DIR/Axel-1.1.0-macos.dmg"

# Step 4: Sign the DMG with EdDSA
echo ""
echo "Step 4: Signing DMG with EdDSA..."
echo "-----------------------------------"

# Get signature from Keychain-stored key
SIGNATURE=$("$SCRIPT_DIR/sign_update" "$DIST_DIR/Axel-1.1.0-macos.dmg" 2>&1)
echo "Signature: $SIGNATURE"

# Extract just the signature value (after "sparkle:edSignature=")
ED_SIGNATURE=$(echo "$SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
if [ -z "$ED_SIGNATURE" ]; then
    # Fallback: the whole output might be the signature
    ED_SIGNATURE="$SIGNATURE"
fi
echo "EdDSA Signature: $ED_SIGNATURE"

# Step 5: Get file info
FILE_SIZE=$(stat -f%z "$DIST_DIR/Axel-1.1.0-macos.dmg")
PUB_DATE=$(date -R)

# Step 6: Create appcast.xml
echo ""
echo "Step 5: Creating appcast.xml..."
echo "-----------------------------------"

cat > "$DIST_DIR/appcast.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Axel Updates</title>
        <link>https://axel.md</link>
        <description>Most recent updates to Axel</description>
        <language>en</language>
        <item>
            <title>Version 1.1.0</title>
            <description><![CDATA[
                <h2>What's New in 1.1.0</h2>
                <ul>
                    <li>Added automatic updates via Sparkle</li>
                    <li>Various bug fixes and improvements</li>
                </ul>
            ]]></description>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>1.1.0</sparkle:version>
            <sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="http://localhost:$LOCAL_SERVER_PORT/Axel-1.1.0-macos.dmg"
                length="$FILE_SIZE"
                type="application/octet-stream"
                sparkle:edSignature="$ED_SIGNATURE"
            />
        </item>
    </channel>
</rss>
EOF

echo "Created: $DIST_DIR/appcast.xml"
cat "$DIST_DIR/appcast.xml"

# Step 6: Temporarily modify Info.plist in the v1.0.0 app to use local server
echo ""
echo "Step 6: Configuring v1.0.0 app to use local server..."
echo "-----------------------------------"

/usr/libexec/PlistBuddy -c "Set :SUFeedURL http://localhost:$LOCAL_SERVER_PORT/appcast.xml" \
    "$DIST_DIR/Axel-1.0.0.app/Contents/Info.plist"

echo "Updated SUFeedURL to: http://localhost:$LOCAL_SERVER_PORT/appcast.xml"

# Step 7: Start local server
echo ""
echo "==================================="
echo "Setup Complete!"
echo "==================================="
echo ""
echo "Files created in: $DIST_DIR"
echo "  - Axel-1.0.0.app (old version)"
echo "  - Axel-1.1.0.app (new version)"
echo "  - Axel-1.1.0-macos.dmg"
echo "  - appcast.xml"
echo ""
echo "To test the update flow:"
echo ""
echo "1. Start local server (in a separate terminal):"
echo "   cd $DIST_DIR && python3 -m http.server $LOCAL_SERVER_PORT"
echo ""
echo "2. Launch the old version:"
echo "   open $DIST_DIR/Axel-1.0.0.app"
echo ""
echo "3. In the app, go to: Axel menu > Check for Updates..."
echo ""
echo "4. You should see an update available for version 1.1.0!"
echo ""
echo "-----------------------------------"
echo "Starting local server now..."
echo "Press Ctrl+C to stop"
echo "-----------------------------------"
echo ""

cd "$DIST_DIR"
python3 -m http.server $LOCAL_SERVER_PORT
