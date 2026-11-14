# Schrodinger for iOS and macOS

Native SwiftUI app. One codebase, two platforms (iOS 26, macOS 26).

- **Data on device**: SwiftData store in the app container. Optional iCloud sync (CloudKit private database) between your own devices — off by default, toggle in Settings, takes effect at next launch. No server of ours anywhere.
- **AI from the device**: calls go straight from the app to the model. Providers: **Apple Intelligence** (on-device FoundationModels, nothing leaves the device), **Claude** (Anthropic API over HTTPS; key stored in this device's Keychain, not synced), and an offline mock.
- **Harness**: one sub-agent per active project, concurrent, draft-only tools (`project_context`, `web_fetch`, workspace `read/write/list_files`, `calendar_events`, `finish`). Runs on a timer while the app is open, on iOS also via Background App Refresh, and on demand.
- **Calendar**: EventKit — agenda of events + due tasks, "Add to calendar" for due-dated tasks, project-linked calendars generate prep-task proposals.
- **Same model as the web app**: numbered outline, `@ai` / `@me` / `@both` and `#mode` tags, shared tasks (AI preps → "your turn"), review/inbox/digest/undo.

## Build

```
brew install xcodegen
cd apple && xcodegen generate
open Schrodinger.xcodeproj
```
Set your team under Signing & Capabilities (or `DEVELOPMENT_TEAM` in `project.yml`). Requires Xcode 26.

## Remote builds on the Mac mini

Same arrangement as Tact. The Mac mini runs a self-hosted GitHub Actions runner (label `schrodinger`) for `.github/workflows/mac-build.yml`:

- Any push that touches `apple/` builds iOS and macOS and runs the unit tests. Nothing is uploaded.
- Pushing a tag named `testflight-<anything>` builds, tests, then archives and uploads both platforms:
  `git tag testflight-$(date -u +%Y%m%d%H%M) && git push origin --tags`
- Actions > Mac build > Run workflow does the same, with a TestFlight checkbox (works from the GitHub mobile app).

Each run posts a check run named **Schrodinger build log** on the commit; read it with `gh api repos/ikaikahussey/schrodinger/commits/<sha>/check-runs`.

Setup on the Mac (once): `zsh apple/setup-mac-runner.sh`. It installs the runner beside Tact's and removes the old launchd poller. Signing material stays on the Mac in `~/.schrodinger-asc.env` and `~/.appstoreconnect`; the workflow uses no repository secrets.

`apple/build.command` is the engine the workflow runs. Double-clicked on a Mac it still pulls, builds, uploads and pushes its log to the `build-logs` branch. `apple/install-automation.command` (the launchd poller) is superseded by the runner; do not install both.

## TestFlight

Manual:

```
xcodebuild -project Schrodinger.xcodeproj -scheme Schrodinger_iOS -configuration Release \
  -archivePath build/Schrodinger.xcarchive archive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/Schrodinger.xcarchive -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates
xcrun altool --upload-app -f build/export/Schrodinger.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```
(or Product → Archive → Distribute App in Xcode.)

