#!/bin/zsh
# One-time setup of the Mac mini as the build machine for Schrodinger, matching Tact's.
#
# Usage (on the Mac):  zsh apple/setup-mac-runner.sh
#
#   1. Installs a GitHub Actions runner (label "schrodinger") as a login agent in
#      ~/actions-runner-schrodinger, so pushes build via .github/workflows/mac-build.yml.
#      It sits beside Tact's runner; personal accounts cannot share one runner across repositories.
#   2. Removes the old launchd poller (org.schrodinger.build), which would otherwise build and
#      upload every push to main a second time.
#   3. Checks what the TestFlight upload needs and says what is missing.
#
# The runner runs as you, in your login session, because signing needs your keychains.

set -euo pipefail
REPO="ikaikahussey/schrodinger"
RUNNER_DIR="$HOME/actions-runner-schrodinger"
RUNNER_NAME="${RUNNER_NAME:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)-schrodinger}"
step() { print -P "\n%B==> $1%b"; }
ok()   { print "    ok: $1"; }

step "Tools"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
xcodebuild -version | head -1
command -v xcodegen >/dev/null || brew install xcodegen
ok "xcodegen"

step "GitHub Actions runner"
mkdir -p "$RUNNER_DIR"; cd "$RUNNER_DIR"
if [[ ! -x ./config.sh ]]; then
  version=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
    | sed -nE 's/.*"tag_name": *"v([^"]+)".*/\1/p' | head -1)
  [[ -n "$version" ]] || { print "Could not look up the runner version."; exit 1; }
  arch=$([[ "$(uname -m)" == arm64 ]] && echo arm64 || echo x64)
  print "    Downloading runner $version ($arch)"
  curl -fsSL -o runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v$version/actions-runner-osx-$arch-$version.tar.gz"
  tar xzf runner.tar.gz && rm runner.tar.gz
fi
if [[ ! -f .runner ]]; then
  token=""
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    token=$(gh api -X POST "repos/$REPO/actions/runners/registration-token" -q .token 2>/dev/null || true)
  fi
  if [[ -z "$token" ]]; then
    print "    Open https://github.com/$REPO/settings/actions/runners/new"
    print "    and copy the token shown after --token in the Configure step."
    read -rs "token?    Paste the token (input hidden): "; print
  fi
  ./config.sh --unattended --replace \
    --url "https://github.com/$REPO" --token "$token" \
    --name "$RUNNER_NAME" --labels schrodinger --work _work
fi
ok "runner registered as $RUNNER_NAME"
if ! ./svc.sh status 2>/dev/null | grep -q 'Started'; then
  ./svc.sh install >/dev/null 2>&1 || true
  ./svc.sh start
fi
ok "runner service started"

step "Old launchd poller"
launchctl bootout "gui/$(id -u)/org.schrodinger.build" 2>/dev/null && print "    stopped" || true
if [[ -f "$HOME/Library/LaunchAgents/org.schrodinger.build.plist" ]]; then
  mv "$HOME/Library/LaunchAgents/org.schrodinger.build.plist" "$HOME/Library/Application Support/Schrodinger/" 2>/dev/null || true
fi
ok "poller not installed"

step "TestFlight signing"
[[ -f "$HOME/.schrodinger-asc.env" ]] && ok "~/.schrodinger-asc.env" \
  || print "    MISSING: ~/.schrodinger-asc.env (run apple/build.command once by hand; it finds the .p8 and writes it)"
security find-identity -v -p codesigning | grep -q '"Apple Distribution' && ok "Apple Distribution certificate" \
  || print "    MISSING: Apple Distribution certificate (created by the first upload run)"

step "Done"
print "Push to build and test. Tag testflight-<anything> to upload. Runner logs: $RUNNER_DIR/_diag"
