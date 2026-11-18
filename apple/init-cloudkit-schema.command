#!/bin/bash
# Double-click in Finder (or run in Terminal) after changing a @Model. Builds a signed Debug Mac app and runs it once
# with -initCloudKitSchema, which writes every record type (CD_Node, CD_Attachment, …) to the CloudKit *Development*
# environment and quits. This Mac must be signed in to iCloud.
#
# Then deploy it: https://icloud.developer.apple.com → iCloud.org.schrodinger.app → Schema → Deploy Schema Changes…
# TestFlight and App Store builds sync against Production and can only create records of deployed types.
#
# Signing uses the App Store Connect key from ~/.schrodinger-asc.env (same as build.command), so Xcode can make a
# development profile that includes iCloud and push without an Apple ID added in Xcode's settings.
set -u
cd "$(dirname "$0")" || exit 1
XC=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -1)
export DEVELOPER_DIR="$XC/Contents/Developer"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
: "${ASC_KEY_ID:=9CLX5GTX69}"
: "${ASC_ISSUER_ID:=69a6de74-1e28-47e3-e053-5b8c7c11a4d1}"
[ -f ~/.schrodinger-asc.env ] && source ~/.schrodinger-asc.env
: "${ASC_KEY_PATH:=$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
AUTH=()
[ -f "$ASC_KEY_PATH" ] && AUTH=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")

xcodegen generate -q || exit 1
DD=build/schema-init
xcodebuild -project Schrodinger.xcodeproj -scheme Schrodinger_macOS -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$DD" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
APP="$DD/Build/Products/Debug/Schrodinger.app"
[ -x "$APP/Contents/MacOS/Schrodinger" ] || { echo "build failed"; exit 1; }
echo "--- writing the schema to CloudKit Development (takes up to a minute)"
# Launched through LaunchServices (-n: a separate instance, so a running copy of the app is left alone). Run straight
# from the shell, the app can't reach CloudKit's services and the requests time out.
OUT=$(mktemp)
open -W -n --stdout "$OUT" --stderr "$OUT" "$APP" --args -initCloudKitSchema
grep -A3 "CloudSync:" "$OUT"
if grep -q "schema initialized" "$OUT"; then STATUS=0; else STATUS=1; fi
rm -f "$OUT"
[ "$STATUS" = 0 ] && echo "Done. Now deploy to Production: https://icloud.developer.apple.com (Schema → Deploy Schema Changes…)"
exit "$STATUS"
