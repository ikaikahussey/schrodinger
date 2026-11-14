#!/bin/bash
# Installs a launchd agent that checks GitHub every 5 minutes and, when main has new commits, runs build.command
# in Terminal (Terminal holds the macOS permission to read your Documents; background jobs do not).
# Run once (double-click). Uninstall: launchctl bootout gui/$(id -u)/org.schrodinger.build; rm ~/Library/LaunchAgents/org.schrodinger.build.plist
set -e
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
SUPPORT=~/Library/Application\ Support/Schrodinger
PLIST=~/Library/LaunchAgents/org.schrodinger.build.plist
mkdir -p "$SUPPORT" ~/Library/LaunchAgents
cat > "$SUPPORT/poll.sh" <<EOF2
#!/bin/bash
# Polls GitHub; launches the build in Terminal when main moves. Lives outside Documents so launchd may run it.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
NEW=\$(git ls-remote https://github.com/ikaikahussey/schrodinger refs/heads/main 2>/dev/null | cut -f1)
[ -z "\$NEW" ] && exit 0
OLD=\$(cat "$SUPPORT/last-sha" 2>/dev/null || echo none)
[ "\$NEW" = "\$OLD" ] && exit 0
echo "\$NEW" > "$SUPPORT/last-sha"
open -a Terminal "$REPO/apple/build.command"
EOF2
chmod +x "$SUPPORT/poll.sh"
cat > "$PLIST" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.schrodinger.build</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SUPPORT/poll.sh</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$SUPPORT/launchd.out</string>
  <key>StandardErrorPath</key><string>$SUPPORT/launchd.err</string>
</dict></plist>
EOF2
launchctl bootout gui/$(id -u)/org.schrodinger.build 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "Installed. Every push to main now opens a build in Terminal within 5 minutes; logs go to the build-logs branch."
echo "A first build is starting now in a new Terminal window. You can close this window."
