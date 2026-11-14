#!/bin/bash
# Build the iOS app for the Simulator and launch it. Double-click to run.
set -u
cd "$(dirname "$0")" || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
XC=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -1); export DEVELOPER_DIR="$XC/Contents/Developer"
git -C .. pull --ff-only -q 2>/dev/null || true
[ -d Schrodinger.xcodeproj ] || xcodegen generate | tail -1
# Pick a simulator: a booted iPhone if any, else the newest available iPhone.
UDID=$(xcrun simctl list devices booted -j | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next((x['udid'] for r in d.values() for x in r if 'iPhone' in x['name']), ''))")
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys; d=json.load(sys.stdin)['devices']
cands=[(r,x) for r,xs in d.items() for x in xs if 'iPhone' in x['name'] and 'SE' not in x['name']]
cands.sort(key=lambda t:(t[0],t[1]['name']))
print(cands[-1][1]['udid'] if cands else '')")
fi
[ -z "$UDID" ] && { echo "No iPhone simulator available. Install one in Xcode → Settings → Components."; exit 1; }
echo "Simulator: $(xcrun simctl list devices | grep "$UDID" | head -1)"
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator
echo "--- building (Debug, simulator)"
xcodebuild -project Schrodinger.xcodeproj -scheme Schrodinger_iOS -configuration Debug -destination "id=$UDID" -derivedDataPath build/sim build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
APP=$(find build/sim/Build/Products -name "Schrodinger.app" -path "*iphonesimulator*" | head -1)
[ -z "$APP" ] && { echo "Build failed; see above."; exit 1; }
xcrun simctl install "$UDID" "$APP" && xcrun simctl launch "$UDID" org.schrodinger.app && echo "Launched. You can close this window."
