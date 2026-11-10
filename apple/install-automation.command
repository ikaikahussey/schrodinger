#!/bin/bash
# Installs a launchd agent that checks GitHub every 5 minutes and runs build.command when main has new commits.
# Run once (double-click). Uninstall: launchctl bootout gui/$(id -u)/org.schrodinger.build; rm ~/Library/LaunchAgents/org.schrodinger.build.plist
set -e
cd "$(dirname "$0")"
SCRIPT="$(pwd)/build.command"
PLIST=~/Library/LaunchAgents/org.schrodinger.build.plist
mkdir -p ~/Library/LaunchAgents build
cat > "$PLIST" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.schrodinger.build</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SCRIPT</string><string>--if-changed</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$(pwd)/build/launchd.out</string>
  <key>StandardErrorPath</key><string>$(pwd)/build/launchd.err</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
</dict></plist>
EOF2
launchctl bootout gui/$(id -u)/org.schrodinger.build 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "Installed. Every push to main now builds here within 5 minutes; logs go to the build-logs branch."
echo "You can close this window."
