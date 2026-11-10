#!/bin/bash
# Double-click in Finder (or run in Terminal). Pulls latest, generates the Xcode project, builds macOS + iOS,
# and uploads to TestFlight when the build passes. The full log is pushed to the `build-logs` branch so it can be
# read remotely. Set ASC_* in ~/.schrodinger-asc.env to enable upload:
#   ASC_KEY_ID=...  ASC_ISSUER_ID=...  ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8  APPLE_TEAM_ID=...
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
LOG="$REPO/apple/build-log.txt"
XC=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -1)
export DEVELOPER_DIR="$XC/Contents/Developer"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
[ -f ~/.schrodinger-asc.env ] && source ~/.schrodinger-asc.env
{
  echo "=== $(date) ==="; echo "Xcode: $XC"; xcodebuild -version
  echo "--- git pull"; git pull --ff-only 2>&1
  cd apple
  echo "--- xcodegen"; which xcodegen || brew install xcodegen 2>&1 | tail -3
  [ -n "${APPLE_TEAM_ID:-}" ] && sed -i '' "s/DEVELOPMENT_TEAM: \"\"/DEVELOPMENT_TEAM: \"$APPLE_TEAM_ID\"/" project.yml
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
      xcodebuild -exportArchive -archivePath "build/$P.xcarchive" -exportPath "build/$P-export" -exportOptionsPlist ExportOptions.plist "${AUTH[@]}" 2>&1 | grep -E "error:|EXPORT (SUCCEEDED|FAILED)|Upload|\*\* " | sort -u
    done
  else
    echo "--- skipping archive/upload (mac=$MAC ios=$IOS asc=${ASC_KEY_ID:+set})"
  fi
  echo "=== done $(date) ==="
} 2>&1 | tee "$LOG"
cd "$REPO"
git add apple/build-log.txt && git commit -q -m "build log $(date +%F_%T)" -- apple/build-log.txt && git push -q origin HEAD:build-logs --force 2>&1 | tail -1
git reset -q --soft HEAD~1 && git reset -q apple/build-log.txt   # keep main clean; log lives on build-logs
echo; echo "Log pushed to branch build-logs. You can close this window."
