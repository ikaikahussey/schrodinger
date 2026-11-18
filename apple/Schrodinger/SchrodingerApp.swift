import SwiftUI
import SwiftData
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

@main
struct SchrodingerApp: App {
    let container: ModelContainer
    @State private var harness: HarnessEngine

    init() {
        let c = AppData.container
        container = c
        _harness = State(initialValue: HarnessEngine(container: c))
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
                task.setTaskCompleted(success: true)
            }
        }
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup { ContentView().environment(harness).task { harness.start() } }
            .modelContainer(container)
            .defaultSize(width: 1280, height: 820)
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
        // Pushes the record types to the CloudKit Development environment and quits (see init-cloudkit-schema.command).
        if CommandLine.arguments.contains("-initCloudKitSchema") { exit(CloudSync.initializeSchema(types: types) ? 0 : 1) }
        #endif
        let sync = UserDefaults.standard.bool(forKey: "iCloudSync")
        let config = ModelConfiguration("Schrodinger", schema: schema, cloudKitDatabase: sync ? .private(CloudSync.containerID) : .none)
        let c: ModelContainer
        // If the store can't be opened with sync, the same store is opened without it, so the app still works with the
        // data already on this device (a separate local store would look empty); Settings says sync failed.
        var openError: Error?
        do { c = try ModelContainer(for: schema, configurations: [config]) }
        catch { openError = error; c = try! ModelContainer(for: schema, configurations: [ModelConfiguration("Schrodinger", schema: schema, cloudKitDatabase: .none)]) }
        CloudSync.shared.opened(sync: sync, error: openError)
        c.mainContext.undoManager = UndoManager()   // enables undo/redo for every edit made through the main context
        return c
    }
}
