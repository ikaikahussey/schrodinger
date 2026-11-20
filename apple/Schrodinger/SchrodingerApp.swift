import SwiftUI
import SwiftData
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

@main
struct SchrodingerApp: App {
    let container: ModelContainer
    @State private var harness: HarnessEngine
    #if os(iOS)
    // iOS hands a finished background transfer (a handed-off item's reply) to the app delegate.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        let c = AppData.container
        container = c
        _harness = State(initialValue: HarnessEngine(container: c))
        Reminders.configure()
        JobQueue.shared.resume()   // the AI's work queue: replies that came in while the app was closed, interrupted jobs
        #if os(iOS)
        let engine = HarnessEngine(container: c)
        // The handler is written in this main-actor context, so Swift checks at run time that it runs on the main actor.
        // With `using: nil` iOS called it on a background queue, which trapped (EXC_BREAKPOINT in
        // _dispatch_assert_queue_fail via swift_task_isCurrentExecutor) whenever iOS woke the app for a background
        // refresh. Deliver it on the main queue instead.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: HarnessEngine.bgIdentifier, using: DispatchQueue.main) { task in
            Task { @MainActor in
                engine.scheduleBackgroundRefresh()
                let work = Task { await engine.runOnce() }
                // iOS calls the expiration handler on a queue of its choosing: keep it free of actor isolation.
                task.expirationHandler = { @Sendable in work.cancel() }
                _ = await work.value
                await Reminders.syncAll(container: c)
                task.setTaskCompleted(success: true)
            }
        }
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        // A standard Mac window: title bar with the close / minimize / zoom buttons, full screen (green button,
        // ⌃⌘F, View > Enter Full Screen), resizable down to a minimum, several windows (File > New Window).
        WindowGroup("Schrodinger") {
            ContentView().environment(harness).task { harness.start() }
                .frame(minWidth: 480, minHeight: 420)
        }
            .modelContainer(container)
            .windowStyle(.titleBar)
            .windowToolbarStyle(.unified(showsTitle: true))
            .windowResizability(.contentMinSize)
            .defaultSize(width: 900, height: 820)
            .commands { UndoCommands(); TextSizeCommands() }
        Settings { SettingsView().modelContainer(container).environment(harness) }
        #else
        WindowGroup { ContentView().environment(harness).task { harness.start() } }
            .modelContainer(container)
        #endif
    }
}

/// The app's one data store, made on first use: by the app at launch, or by a Shortcuts action (Add to Schrodinger)
/// if that runs first.
@MainActor enum AppData {
    static let container: ModelContainer = make()

    private static func make() -> ModelContainer {
        let schema = Schema([Node.self, Proposal.self, ActivityEntry.self, Digest.self, WorkspaceFile.self, HarnessRun.self, Attachment.self])
        // All data is on device. iCloud (CloudKit private database) sync is opt-in and only between the user's own devices.
        let types: [any PersistentModel.Type] = [Node.self, Proposal.self, ActivityEntry.self, Digest.self, WorkspaceFile.self, HarnessRun.self, Attachment.self]
        #if DEBUG
        if CommandLine.arguments.contains("-initCloudKitSchema") { CloudSync.initializeSchema(types: types) }
        #endif
        let sync = UserDefaults.standard.bool(forKey: "iCloudSync")
        let config = ModelConfiguration("Schrodinger", schema: schema, cloudKitDatabase: sync ? .private(CloudSync.containerID) : .none)
        let c: ModelContainer
        // If the synced store can't be opened, a local one is used so the app still works; Settings says so.
        var openError: Error?
        do { c = try ModelContainer(for: schema, configurations: [config]) }
        catch { openError = error; c = try! ModelContainer(for: schema, configurations: [ModelConfiguration("Schrodinger-local", schema: schema, cloudKitDatabase: .none)]) }
        CloudSync.shared.opened(sync: sync, error: openError)
        Store(c.mainContext).migrateModesToTags()   // items from before modes became tags
        Store(c.mainContext).pruneDoneDated()       // checked-off dated items, a week after they were done
        Store(c.mainContext).pruneHistory()         // deleted-item history, 90 days back
        c.mainContext.undoManager = UndoManager()   // enables undo/redo for every edit made through the main context
        return c
    }
}

#if os(macOS)
/// View ▸ Bigger (⌘+), Smaller (⌘−), Actual Size (⌘0): the size of the outline's text, kept between launches.
struct TextSizeCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            let look = Appearance.shared
            Divider()
            Button("Bigger") { look.enlargeText() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!look.canEnlargeText)
            Button("Smaller") { look.shrinkText() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!look.canShrinkText)
            Button("Actual Size") { look.textScale = 1 }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(look.textScale == 1)
            Divider()
        }
    }
}
#endif
