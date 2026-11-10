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
        let schema = Schema([Node.self, Proposal.self, ActivityEntry.self, Digest.self, WorkspaceFile.self, HarnessRun.self])
        // All data is on device. iCloud (CloudKit private database) sync is opt-in and only between the user's own devices.
        let sync = UserDefaults.standard.bool(forKey: "iCloudSync")
        let config = ModelConfiguration("Schrodinger", schema: schema, cloudKitDatabase: sync ? .private("iCloud.org.schrodinger.app") : .none)
        let c: ModelContainer
        do { c = try ModelContainer(for: schema, configurations: [config]) }
        catch { c = try! ModelContainer(for: schema, configurations: [ModelConfiguration("Schrodinger-local", schema: schema, cloudKitDatabase: .none)]) }
        container = c
        _harness = State(initialValue: HarnessEngine(container: c))
        #if os(iOS)
        let engine = HarnessEngine(container: c)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: HarnessEngine.bgIdentifier, using: nil) { task in
            Task { @MainActor in
                engine.scheduleBackgroundRefresh()
                let work = Task { await engine.runOnce() }
                task.expirationHandler = { work.cancel() }
                _ = await work.value
                task.setTaskCompleted(success: true)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(harness)
                .task { harness.start() }
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        Settings { SettingsView().modelContainer(container).environment(harness) }
        #endif
    }
}
