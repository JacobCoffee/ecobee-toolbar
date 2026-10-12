#!/usr/bin/env bash
# Create or renew the HomeKit provisioning profile with the Apple ID signed
# in to Xcode, then record it for scripts/bundle.sh. Needs a paid Developer
# Program team: free Personal Teams can't get HomeKit for Mac Catalyst.
# Profiles last a year; when one expires, rerun this, then scripts/bundle.sh.
#
#   TEAM_ID=ABCDE12345 scripts/provision.sh
#   scripts/provision.sh                  # lists the paid teams signed in to Xcode
set -euo pipefail

cd "$(dirname "$0")/.."
export HELPER_ID="${HELPER_ID:-com.jacobcoffee.EcobeeBar.HomeKit}"
OUT="build/provisioning"
mkdir -p "$OUT"
export STUB_DIR="$PWD/$OUT"

if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools ]]; then
    echo "Xcode isn't the active developer directory. Run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

if [[ -z "${TEAM_ID:-}" ]]; then
    # Never guess: the signed-in account may belong to an organization's team.
    echo "Set TEAM_ID to the paid Developer Program team to provision with." >&2
    echo "Paid teams signed in to Xcode:" >&2
    defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -I -c '
import plistlib, sys
prefs = plistlib.loads(sys.stdin.buffer.read())
seen = set()
for ts in prefs.get("IDEProvisioningTeamByIdentifier", {}).values():
    for t in ts:
        if not t.get("isFreeProvisioningTeam") and t["teamID"] not in seen:
            seen.add(t["teamID"])
            print("  " + t["teamID"] + "  " + t.get("teamName", ""))
if not seen:
    print("  (none; free Personal Teams cannot get HomeKit for Mac Catalyst)")
' >&2
    exit 1
fi
echo "Provisioning $HELPER_ID for team $TEAM_ID"

xcodegen generate --quiet --spec dev/provisioning/project.yml --project "$OUT"
xcodebuild -quiet \
    -project "$OUT/ProvisioningStub.xcodeproj" -scheme ProvisioningStub \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$OUT/DerivedData" \
    -allowProvisioningUpdates \
    build

STUB_APP=$(find "$OUT/DerivedData/Build/Products" -name ProvisioningStub.app -maxdepth 2 | head -1)
cp "$STUB_APP/Contents/embedded.provisionprofile" build/HomeKit.provisionprofile
IDENTITY=$(codesign -dvv "$STUB_APP" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)$/\1/p' | head -1)
EXPIRES=$(security cms -D -i build/HomeKit.provisionprofile | plutil -extract ExpirationDate raw -o - -)

cat > build/signing.env <<ENV
SIGN_IDENTITY="$IDENTITY"
HOMEKIT_PROFILE="$PWD/build/HomeKit.provisionprofile"
ENV
echo "Profile for $HELPER_ID signed by \"$IDENTITY\", expires $EXPIRES"
echo "Now run scripts/bundle.sh"
