# Schrodinger for iOS and macOS

Native SwiftUI app. One codebase, two platforms (iOS 26, macOS 26).

- **Data on device**: SwiftData store in the app container. Optional iCloud sync (CloudKit private database) between your own devices — off by default, toggle in Settings, takes effect at next launch. No server of ours anywhere.
- **AI from the device**: calls go straight from the app to the model. Providers: **Apple Intelligence** (on-device FoundationModels, nothing leaves the device), **Local model** (Mac only: an OpenAI-compatible server on the same Mac such as Ollama or LM Studio, `AI/LocalProvider.swift`; free, nothing leaves the computer, works while the app is open), **Claude** (Anthropic API over HTTPS; the model is chosen in Settings from the list the key can use). The Claude key is kept in the Keychain and syncs between your devices through iCloud Keychain (enter it once); where that is unavailable it stays on the device.
- **Hand-offs** (`Harness/JobQueue.swift`): the wand in an item's field (joined to the glyph for who holds the item; sending an item of yours makes the AI its holder) (or the same wand on an AI item's row) hands the item to the AI. Each hand-off is a job that starts at once; jobs run side by side. With Claude a job is **one request**: the item and its context go in, Claude runs web search and web fetch on Anthropic's side, and hands the result back by calling `submit_result`. The request is carried by a background URL session, so it finishes with the app suspended or closed and the app is woken to apply it. Apple Intelligence and a local model run in the app's process, while it is open.
- **Results show up in the outline**: the result is put on the item, follow-up steps become its children, notes, links and dates are added, and the item goes to review. Review means one thing everywhere (the Review filter, the box at the bottom of the outline, the item's Approve button): the AI returned its result and the owner has not approved it. Approve makes it done; Redo hands it back. Done holds finished to-dos and approved AI results. Changes are in-app only, recorded in History and undoable. The item's row carries the AI's status as a line under its title: working (with Stop), failed and why (with Try again and Dismiss), or what came back. The row also shows a result glyph until the item is opened, a notification is posted, and header menu → Results lists everything handed off on this device.
- **Weave** (`Harness/Weave.swift`): an item that has items under it carries a Weave button in its field (and Weave into one piece in its menu). It makes the item and everything under it into one long-form piece of writing: the items under it are the threads (titles, notes, results, links, in outline order), and the item's own notes say what the piece is for (audience, voice, length). The piece comes back onto the item as its result, so it is read full screen, shared as Markdown, and commented on like any result; a comment weaves it again with the comment. Passages end with a link (↗) to the item they came from, and the piece ends with a list of every thread, each a link; tapping one opens that item in the outline (`item:` links, handled in `ContentView`). Weaving does not change the item's status or holder. Each weave is recorded in the item's activity with the text it replaced. With Claude it is one background request with no tools; Apple Intelligence and a local model weave as many threads as they can read.
- **Comments on a result** (`Views/ResultViewer.swift`): under the result, a comment form takes the edits it needs; sending it records the comment on the item and hands the item back to the AI to redo.
- **Results to review** (`Views/ReviewBox.swift`): the items in review (the same set as the Review filter; unopened ones are marked New) are listed in a box at the bottom of the outline, above the calendar box. Tap one to open its item. Like the calendar box it can be pushed off the bottom, leaving a tab with the count.
- **The AI acts only when asked**: it works on an item when that item is handed off, and nothing else starts it. There is no automatic pass over the outline.
- **Recommended tasks**, on request only (header menu → Recommend tasks): the AI reads the whole outline and recommends up to five tasks. Each appears as a dimmed row where it would go, with its reason: + keeps it, x dismisses it. Nothing is recommended twice.
- **No background passes**: nothing looks over the outline on a timer. There are no stale or blocked notices; the Inbox holds only suggestions asked for on an item. iOS Background App Refresh is used only to keep reminders and the badge current.
- **Calendar**: EventKit — agenda of events + due tasks, "Add to calendar" for due-dated tasks, project-linked calendars generate prep-task proposals.
- **Filters**: tap the search field for the options under it: a grid of what to show (Mine, AI, Review, Blocked, This week, Done), then a row of saved views, then a row of tags. Each filter and saved view carries a count of the items it shows (filters count what is in view: the zoomed item, or everything). Tap one to turn it on, again to turn it off. They stay visible while a filter is on. Each filter button carries the glyph the item controls use for that holder, status or date, and the filter that is on is titled above the outline (glyph, name, what it shows). Inbox has Clear All.
- **Zoom**: hold an item (or spread two fingers on it) to zoom in. The zoomed item is drawn as a top-level item: at the left edge, in the top level's color, with no ancestor rails, and its children one level in from there. Its mark keeps its count. The count in a mark is every item below (children, grandchildren, and so on). It is exact up to 999, then in thousands ("2k"). The header path shows where it sits and leads back out.
- **Search index** (`Store/SearchIndex.swift`): the in-app search, the filters and their counts read an index of each item's lowercased text and tags, rebuilt whenever an item's text changes or an item is added or removed. Items are also in the system's search (Spotlight) on iPhone, iPad and Mac: changed and new items are indexed again and deleted ones removed whenever items change; choosing a result opens the item in the outline. The system index stays on the device.
- **Saved views**: header menu → Save this view… keeps the current search, filter, tag and zoom under a name. Saved views are listed in the same menu and as buttons under the search field; hold (or right-click) a button to rename or delete it. They are stored with the rest of the data (and sync with it), with no extra iCloud record type.
- **History**: header menu → History turns the outline into a marked-up view of what changed (today, 7 days, 30 days): added items in green, deleted items struck through where they were, each with a Reinstate button, renamed items with their old text above. Done in the bar under the header leaves the mode. Deleted items are remembered for 90 days.
- **Same model as the web app**: numbered outline, `@ai` / `@me` / `@both` and `#mode` tags, shared tasks (AI preps → "your turn"), review/inbox/digest/undo.
- **Jobs are per device**: the queue (`Application Support/Jobs`) is not synced, so it adds no iCloud record type; what a job produces is written to the outline, which syncs.

## Build

```
brew install xcodegen
cd apple && xcodegen generate
open Schrodinger.xcodeproj
```
Set your team under Signing & Capabilities (or `DEVELOPMENT_TEAM` in `project.yml`). Requires Xcode 26.

## Automated builds on your own Mac (no runner)

`apple/build.command` pulls, generates, compiles both platforms, runs tests, archives and uploads when `~/.schrodinger-asc.env` is present, and pushes its log to the `build-logs` branch. Double-click `apple/install-automation.command` once to install a launchd agent that runs it whenever `main` changes (checked every 5 min). The upload needs an App Store Connect API key in `~/.schrodinger-asc.env` (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`, `APPLE_TEAM_ID`) and an app record with bundle ID `org.schrodinger.app`.

## TestFlight

Automated: `.github/workflows/testflight.yml` runs on a self-hosted macOS runner (the Mac mini already runs one for Tact). Register that runner for this repo (or at the account level), add secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `APPLE_TEAM_ID`, then push to `main` or run the workflow manually. `ExportOptions.plist` uploads straight to App Store Connect.

Manual:

```
xcodebuild -project Schrodinger.xcodeproj -scheme Schrodinger_iOS -configuration Release \
  -archivePath build/Schrodinger.xcarchive archive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/Schrodinger.xcarchive -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates
xcrun altool --upload-app -f build/export/Schrodinger.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```
(or Product → Archive → Distribute App in Xcode.)

## Status

Written without access to Xcode; not yet compiled. Expect a round of compiler fixes on first build, most likely around SwiftData `#Predicate` forms, `onKeyPress` modifiers, and the FoundationModels `Tool` signature.
