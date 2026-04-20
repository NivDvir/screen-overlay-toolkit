#!/bin/bash
# Build GroundingKit and package as a macOS .app bundle
# Ported from AXVS's build-app.sh, adapted for the clone/future GroundingKit.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="GroundingKit"
BINARY_NAME="GroundingKitApp"  # matches Package.swift executable target name
# (library target is "GroundingKit"; inside the bundle the binary is copied to "GroundingKitAgent")
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."
cd "$SCRIPT_DIR"

# Package.swift pins mlx-swift-lm to NivDvir's fork (commit b4ea2216) which contains
# the MROPE fixes for Qwen2.5-VL. Upstream ml-explore/mlx-swift-lm@8c9dd63 does NOT
# have these fixes and produces broken VLM output ("need 2 panels, got 0").
# See BUILD_NOTES.md for the incident report. xcodebuild auto-resolves from the fork.
xcodebuild -scheme "$BINARY_NAME" -configuration Debug -destination 'platform=macOS' build -quiet 2>&1 | tail -3

# Find the freshly built binary
BINARY=$(find ~/Library/Developer/Xcode/DerivedData/GroundingKit-axvs-clone-*/Build/Products/Debug -name "$BINARY_NAME" -type f 2>/dev/null | head -1)
if [ -z "$BINARY" ] || [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found"
    exit 1
fi
echo "Binary: $BINARY"

echo "Packaging .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Watchdog launcher script (CFBundleExecutable)
# Restarts the binary every 5 minutes for fresh GPU/Metal state.
# Also restarts on /tmp/ccsv_restart signal file.
cat > "$APP_BUNDLE/Contents/MacOS/$APP_NAME" << 'LAUNCHER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$DIR/GroundingKitAgent"
WATCHDOG=300  # 5 minutes

while true; do
    rm -f /tmp/ccsv_restart /tmp/ccsv_reset_flag 2>/dev/null

    "$BINARY" > /tmp/ccsv_overlay.log 2>&1 &
    PID=$!
    START=$(date +%s)

    while kill -0 $PID 2>/dev/null; do
        sleep 2
        NOW=$(date +%s)
        ELAPSED=$((NOW - START))

        if [ -f /tmp/ccsv_restart ]; then
            rm -f /tmp/ccsv_restart
            echo "[Launcher] Restart signal — restarting..." >> /tmp/ccsv_overlay.log
            break
        fi

        if [ "$ELAPSED" -ge "$WATCHDOG" ]; then
            echo "[Launcher] Watchdog 5min — restarting fresh..." >> /tmp/ccsv_overlay.log
            break
        fi
    done

    kill $PID 2>/dev/null
    wait $PID 2>/dev/null
    sleep 1
done
LAUNCHER
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy the real binary with agent suffix
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/GroundingKitAgent"

# Copy resource bundles (MLX Metal library etc)
BUILD_DIR="$(dirname "$BINARY")"
for bundle in "$BUILD_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then
        echo "  Copying $(basename "$bundle")"
        cp -r "$bundle" "$APP_BUNDLE/Contents/Resources/"
    fi
done

# App icon — regenerate via scripts/generate_icon.py if you change the art
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "  Copied AppIcon.icns"
fi

# Info.plist — matches AXVS structure for TCC and rendering consistency
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>GroundingKit</string>
    <key>CFBundleIdentifier</key>
    <string>com.nivdvir.groundingkit</string>
    <key>CFBundleName</key>
    <string>GroundingKit</string>
    <key>CFBundleDisplayName</key>
    <string>GroundingKit</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT license — © 2026 Niv Dvir. Uses Qwen2.5-VL (Alibaba), MLX (Apple), mlx-swift-lm (ml-explore).</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppSleepDisabled</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>GroundingKit needs Screen Recording to detect UI panels and render guidance overlays.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>GroundingKit needs automation access to interact with Chrome.</string>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Use stable dev cert if available (persists TCC permissions across rebuilds)
SIGN_ID="GhostOverlay Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --sign "$SIGN_ID" "$APP_BUNDLE/Contents/MacOS/GroundingKitAgent" 2>/dev/null
    echo "  Signed with $SIGN_ID cert"
else
    codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/GroundingKitAgent" 2>/dev/null
    echo "  Ad-hoc signed"
fi
xattr -cr "$APP_BUNDLE" 2>/dev/null

echo ""
echo "Done. App bundle at:"
echo "  $APP_BUNDLE"
echo ""
echo "Launch:"
echo "  open \"$APP_BUNDLE\""
