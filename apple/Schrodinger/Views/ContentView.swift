import SwiftUI
import SwiftData

enum Panel: String, CaseIterable, Identifiable {
    case outline, batch, inbox, results, calendar, digest, activity, settings
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    // The outline is the app; the others open as a sheet over it (from the header's menu: Inbox, and Settings on
    // iPhone/iPad). Batch, Calendar, Digest and Activity are kept in code but not reachable from the menu.
    var icon: String {
        switch self {
        case .outline: "list.bullet.indent"; case .batch: "square.stack.3d.up"
        case .inbox: "tray"; case .results: "sparkles"; case .calendar: "calendar"; case .digest: "doc.text"; case .activity: "clock"; case .settings: "gear"
        }
    }
}

@MainActor
@Observable
final class Selection {
    var nodeID: UUID? = nil
    var panel: Panel = .outline
    /// Item whose info (action strip + drafts, context, details) is open under its row in the outline.
    var infoID: UUID? = nil
    /// Set when another screen asks the outline to show an item: the outline expands its parents and scrolls to it.
    var revealID: UUID? = nil
    /// An item with children whose Delete was tapped: the outline asks whether its children go too.
    var deleteAskID: UUID? = nil
    /// Show an item from anywhere in the app: switch to the outline and open its info.
    func open(_ id: UUID) { panel = .outline; nodeID = id; infoID = id; revealID = id }
}

struct ContentView: View {
    @State private var sel = Selection()
    @State private var router = ReminderRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // The same on every platform: no sidebar or tab bar, the outline is the app. Inbox (and, on iPhone/iPad,
        // Settings) open from the header's menu as a sheet; on the Mac, Settings is its own window (⌘,).
        NavigationStack { OutlineView(sel: sel) }
            #if os(iOS)
            .shakeToUndo()
            #endif
            .sheet(item: Binding(get: { sel.panel == .outline ? nil : sel.panel }, set: { sel.panel = $0 ?? .outline })) { p in
                NavigationStack {
                    panelView(p)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sel.panel = .outline }.fontWeight(.semibold) } }
                }
                #if os(macOS)
                .frame(minWidth: 520, idealWidth: 620, minHeight: 480, idealHeight: 640)
                #endif
                .environment(sel)
                .font(Appearance.shared.font.font(.body))
            }
        .environment(sel)
        .font(Appearance.shared.font.font(.body))
        // A tapped notification opens its item.
        .onChange(of: router.openID, initial: true) { _, id in if let id { sel.open(id); router.openID = nil } }
        // Back in the foreground: time has passed, so the badge and the next notifications are brought up to date.
        .onChange(of: scenePhase) { _, p in if p == .active { Task { await Reminders.syncAll(container: AppData.container) } } }
        // No global Run button: an item is handed to the AI from its own row or field (see NodeRow).
    }

    @ViewBuilder
    private func panelView(_ p: Panel) -> some View {
        switch p {
        case .outline: OutlineView(sel: sel)
        case .batch: BatchView(sel: sel)
        case .inbox: InboxView(sel: sel)
        case .results: ResultsView(sel: sel)
        case .calendar: CalendarView(sel: sel)
        case .digest: DigestView(sel: sel)
        case .activity: ActivityView()
        case .settings: SettingsView()
        }
    }
}
