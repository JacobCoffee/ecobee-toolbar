#!/usr/bin/env bash
# Build EcobeeBar.app (AppKit menu bar app) with the embedded Mac Catalyst
# HomeKit helper. Works with only the Command Line Tools installed.
#
#   scripts/bundle.sh
#       Ad-hoc signed. The helper has no HomeKit entitlement, so the app
#       launches but shows "HomeKit Signing Required".
#
#   SIGN_IDENTITY="Apple Development: Your Name (ABCDE12345)" \
#   HOMEKIT_PROFILE=~/Downloads/EcobeeBar_HomeKit.provisionprofile \
#   scripts/bundle.sh
#       Signs the helper with com.apple.developer.homekit using the profile
#       (a Mac Catalyst development profile with HomeKit enabled). The
#       helper's bundle ID is taken from the profile.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.2.0}"
# Written by scripts/provision.sh; explicit environment variables win.
if [[ -f build/signing.env && -z "${HOMEKIT_PROFILE:-}" ]]; then
    # shellcheck source=/dev/null
    source build/signing.env
fi
IDENTITY="${SIGN_IDENTITY:--}"
APP="build/EcobeeBar.app"
HELPER="$APP/Contents/Helpers/EcobeeBar HomeKit.app"
HELPER_ID="com.jacobcoffee.EcobeeBar.HomeKit"
WORK="build/work"
mkdir -p "$WORK"

if [[ -n "${HOMEKIT_PROFILE:-}" ]]; then
    [[ "$IDENTITY" != "-" ]] || { echo "HOMEKIT_PROFILE needs SIGN_IDENTITY too" >&2; exit 1; }
    security cms -D -i "$HOMEKIT_PROFILE" > "$WORK/profile.plist"
    APP_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$WORK/profile.plist")
    TEAM_ID=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$WORK/profile.plist")
    if ! /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.homekit' "$WORK/profile.plist" >/dev/null 2>&1; then
        echo "Profile $HOMEKIT_PROFILE does not include the HomeKit capability" >&2
        exit 1
    fi
    HELPER_ID="${APP_IDENTIFIER#"$TEAM_ID".}"
    [[ "$HELPER_ID" != *"*"* ]] || { echo "HomeKit needs an explicit App ID, not $APP_IDENTIFIER" >&2; exit 1; }
fi

# --- menu bar app (SwiftPM) ---
swift build -c release --product EcobeeBar
BIN="$(swift build -c release --show-bin-path)/EcobeeBar"

# --- HomeKit helper (Mac Catalyst; SwiftPM can't target it) ---
SDK="$(xcrun --show-sdk-path)"
IOS="$SDK/System/iOSSupport"
swiftc -O -parse-as-library \
    -target arm64-apple-ios17.0-macabi -sdk "$SDK" \
    -Fsystem "$IOS/System/Library/Frameworks" -I "$IOS/usr/lib/swift" -L "$IOS/usr/lib/swift" \
    -module-name EcobeeBarHomeKit \
    Helper/*.swift Sources/EcobeeKit/*.swift \
    -o "$WORK/EcobeeBar HomeKit"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$HELPER/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/EcobeeBar"
cp "$WORK/EcobeeBar HomeKit" "$HELPER/Contents/MacOS/EcobeeBar HomeKit"

cat > "$HELPER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>EcobeeBar HomeKit</string>
    <key>CFBundleDisplayName</key><string>EcobeeBar</string>
    <key>CFBundleIdentifier</key><string>${HELPER_ID}</string>
    <key>CFBundleExecutable</key><string>EcobeeBar HomeKit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>UIDeviceFamily</key><array><integer>2</integer><integer>6</integer></array>
    <key>UIApplicationSceneManifest</key>
    <dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
    <key>NSHomeKitUsageDescription</key>
    <string>EcobeeBar shows and controls the thermostats in your Apple Home from the menu bar.</string>
</dict>
</plist>
PLIST

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
    <!-- TCC attributes the nested helper's HomeKit request to this app. -->
    <key>NSHomeKitUsageDescription</key>
    <string>EcobeeBar shows and controls the thermostats in your Apple Home from the menu bar.</string>
</dict>
</plist>
PLIST

# Inner bundle first, then the outer app (no --deep, so the helper keeps its entitlements).
if [[ -n "${HOMEKIT_PROFILE:-}" ]]; then
    cp "$HOMEKIT_PROFILE" "$HELPER/Contents/embedded.provisionprofile"
    cat > "$WORK/helper.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.application-identifier</key><string>${APP_IDENTIFIER}</string>
    <key>com.apple.developer.team-identifier</key><string>${TEAM_ID}</string>
    <key>com.apple.developer.homekit</key><true/>
</dict>
</plist>
PLIST
    codesign --force --options runtime --entitlements "$WORK/helper.entitlements" --sign "$IDENTITY" "$HELPER"
else
    echo "note: no HOMEKIT_PROFILE; helper is signed without the HomeKit entitlement" >&2
    codesign --force --options runtime --sign - "$HELPER"
fi
codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "Built $APP (helper: $HELPER_ID)"
