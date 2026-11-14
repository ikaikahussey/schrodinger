#!/bin/bash
# Double-click in Finder (or run in Terminal). Pulls latest, generates the Xcode project, builds macOS + iOS,
# and uploads to TestFlight when the build passes. The full log is pushed to the `build-logs` branch so it can be
# read remotely. Set ASC_* in ~/.schrodinger-asc.env to enable upload:
#   ASC_KEY_ID=...  ASC_ISSUER_ID=...  ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8  APPLE_TEAM_ID=...
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
LOG="$REPO/apple/build-log.txt"
mkdir -p "$REPO/apple/build"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# --if-changed (used by the launchd poller): pull and exit unless main moved since the last build.
if [ "${1:-}" = "--if-changed" ]; then
  git fetch -q origin main 2>/dev/null
  NEW=$(git rev-parse origin/main); OLD=$(cat "$REPO/apple/build/.last-sha" 2>/dev/null || echo none)
  [ "$NEW" = "$OLD" ] && exit 0
fi
XC=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -1)
export DEVELOPER_DIR="$XC/Contents/Developer"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# App Store Connect credentials. Non-secret IDs have defaults; the .p8 is located automatically the first time
# (searched in ~/.appstoreconnect/private_keys, ~/Downloads, ~/Desktop, ~/Documents, ~) and moved into place.
: "${ASC_KEY_ID:=9CLX5GTX69}"
: "${ASC_ISSUER_ID:=69a6de74-1e28-47e3-e053-5b8c7c11a4d1}"
: "${APPLE_TEAM_ID:=3D52FT6PP7}"
[ -f ~/.schrodinger-asc.env ] && source ~/.schrodinger-asc.env
KEYDIR=~/.appstoreconnect/private_keys
if [ ! -f "${ASC_KEY_PATH:-$KEYDIR/AuthKey_$ASC_KEY_ID.p8}" ]; then
  FOUND=$(find "$KEYDIR" ~/Downloads ~/Desktop ~/Documents ~ -maxdepth 2 -name "AuthKey_$ASC_KEY_ID.p8" 2>/dev/null | head -1)
  [ -z "$FOUND" ] && FOUND=$(find ~/Downloads ~/Desktop ~/Documents ~ -maxdepth 2 -name 'AuthKey_*.p8' 2>/dev/null | xargs -I{} stat -f '%m {}' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  if [ -n "$FOUND" ]; then
    mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
    ASC_KEY_ID=$(basename "$FOUND" .p8 | sed 's/^AuthKey_//')
    cp "$FOUND" "$KEYDIR/AuthKey_$ASC_KEY_ID.p8"; chmod 600 "$KEYDIR/AuthKey_$ASC_KEY_ID.p8"
    ASC_KEY_PATH="$KEYDIR/AuthKey_$ASC_KEY_ID.p8"
    printf 'ASC_KEY_ID=%s\nASC_ISSUER_ID=%s\nASC_KEY_PATH=%s\nAPPLE_TEAM_ID=%s\n' "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$ASC_KEY_PATH" "$APPLE_TEAM_ID" > ~/.schrodinger-asc.env
    chmod 600 ~/.schrodinger-asc.env
  fi
fi
: "${ASC_KEY_PATH:=$KEYDIR/AuthKey_$ASC_KEY_ID.p8}"
[ -f "$ASC_KEY_PATH" ] || ASC_KEY_ID=""   # no key available → compile/test only
export ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH APPLE_TEAM_ID
{
  echo "=== $(date) ==="; echo "Xcode: $XC"; xcodebuild -version
  echo "ASC key: ${ASC_KEY_ID:-none} ($( [ -f "${ASC_KEY_PATH:-/nonexistent}" ] && echo present || echo missing))  team: $APPLE_TEAM_ID"
  echo "--- git pull"; git pull --ff-only 2>&1
  cd apple
  echo "--- xcodegen"; which xcodegen || brew install xcodegen 2>&1 | tail -3
  sed -i '' -E "s/DEVELOPMENT_TEAM: \"[A-Z0-9]*\"/DEVELOPMENT_TEAM: \"$APPLE_TEAM_ID\"/" project.yml
  xcodegen generate 2>&1 | tail -5
  echo "--- build macOS (compile check)"
  xcodebuild -project Schrodinger.xcodeproj -scheme Schrodinger_macOS -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)|\*\* " | sort -u
  MAC=${PIPESTATUS[0]}
  echo "--- build iOS (compile check)"
  xcodebuild -project Schrodinger.xcodeproj -scheme Schrodinger_iOS -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)|\*\* " | sort -u
  IOS=${PIPESTATUS[0]}
  echo "--- tests macOS"
  xcodebuild test -project Schrodinger.xcodeproj -scheme Schrodinger_macOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Test Case|Executed|\*\* " | tail -30
  if [ "$MAC" = 0 ] && [ "$IOS" = 0 ] && [ -n "${ASC_KEY_ID:-}" ]; then
    AUTH=(-allowProvisioningUpdates -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
    BN=$(date +%Y%m%d%H%M)
    for P in iOS macOS; do
      echo "--- archive $P"
      xcodebuild -project Schrodinger.xcodeproj -scheme Schrodinger_$P -configuration Release -destination "generic/platform=$P" -archivePath "build/$P.xcarchive" archive CURRENT_PROJECT_VERSION=$BN "${AUTH[@]}" 2>&1 | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)|\*\* " | sort -u
      echo "--- upload $P"
      xcodebuild -exportArchive -archivePath "build/$P.xcarchive" -exportPath "build/$P-export" -exportOptionsPlist ExportOptions.plist "${AUTH[@]}" 2>&1 | grep -E "error:|EXPORT (SUCCEEDED|FAILED)|[Uu]pload|\*\* " | sort -u
    done
  else
    echo "--- skipping archive/upload (mac=$MAC ios=$IOS asc=${ASC_KEY_ID:+set})"
  fi
  echo "=== done $(date) ==="
} 2>&1 | tee "$LOG"
cd "$REPO"
git rev-parse HEAD > "$REPO/apple/build/.last-sha"
git add -f apple/build-log.txt && git commit -q -m "build log $(date +%F_%T)" -- apple/build-log.txt && git push -q origin HEAD:build-logs --force 2>&1 | tail -1
git reset -q --soft HEAD~1 && git reset -q apple/build-log.txt   # keep main clean; log lives on build-logs
echo; echo "Log pushed to branch build-logs. You can close this window."; exit 0
