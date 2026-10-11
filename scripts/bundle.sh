#!/usr/bin/env bash
# Build EcobeeBar.app with SwiftPM (no Xcode required).
#   scripts/bundle.sh            → build/EcobeeBar.app (release, ad-hoc signed)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/bundle.sh
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
APP="build/EcobeeBar.app"

swift build -c "$CONFIG" --product EcobeeBar
BIN="$(swift build -c "$CONFIG" --show-bin-path)/EcobeeBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EcobeeBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>EcobeeBar</string>
    <key>CFBundleDisplayName</key><string>EcobeeBar</string>
    <key>CFBundleIdentifier</key><string>com.jacobcoffee.EcobeeBar</string>
    <key>CFBundleExecutable</key><string>EcobeeBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>EcobeeBar connects to your ecobee thermostat over your local network using HomeKit.</string>
    <key>NSBonjourServices</key>
    <array><string>_hap._tcp</string></array>
</dict>
</plist>
PLIST

codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
