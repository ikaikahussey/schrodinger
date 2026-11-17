import SwiftUI
import SwiftData

enum Panel: String, CaseIterable, Identifiable {
    case outline, batch, inbox, calendar, digest, activity, settings
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Panels kept in code but not shown in navigation. Calendar is hidden pending a decision to remove it; Batch is
    /// replaced by the filter bar on the outline.
    static let hidden: Set<Panel> = [.calendar, .settings, .batch]
    static var navItems: [Panel] { allCases.filter { !hidden.contains($0) } }
    var icon: String {
        switch self {
        case .outline: "list.bullet.indent"; case .batch: "square.stack.3d.up"
        case .inbox: "tray"; case .calendar: "calendar"; case .digest: "doc.text"; case .activity: "clock"; case .settings: "gear"
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
    /// Show an item from anywhere in the app: switch to the outline and open its info.
    func open(_ id: UUID) { panel = .outline; nodeID = id; infoID = id; revealID = id }
}

struct ContentView: View {
    @Environment(HarnessEngine.self) private var harness
    @Environment(\.modelContext) private var ctx
    @State private var sel = Selection()
    @Query(filter: #Predicate<Proposal> { $0.statusRaw == "open" }) private var openProposals: [Proposal]

    var body: some View {
        Group {
            #if os(macOS)
            // Sidebar + one panel. An item's details open inline in the outline (tap its squares), not in a separate column.
            NavigationSplitView {
                List(selection: Binding(get: { sel.panel }, set: { if let p = $0 { sel.panel = p } })) {
                    ForEach(Panel.navItems) { p in
                        Label(p.label, systemImage: p.icon).badge(badge(p)).tag(p)
                    }
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 190)
            } detail: {
                NavigationStack { panelView(sel.panel) }.navigationSplitViewColumnWidth(min: 420, ideal: 760)
            }
            #else
            // No tab bar: the outline is the app. Inbox and Settings open from the header's menu as a sheet.
            NavigationStack { OutlineView(sel: sel) }
                .shakeToUndo()
                .sheet(item: Binding(get: { sel.panel == .outline ? nil : sel.panel }, set: { sel.panel = $0 ?? .outline })) { p in
                    NavigationStack {
                        panelView(p)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sel.panel = .outline }.fontWeight(.semibold) } }
                    }
                    .environment(sel)
                    .environment(harness)
                    .font(Appearance.shared.font.font(.body))
                }
            #endif
        }
        .environment(sel)
        .font(Appearance.shared.font.font(.body))
        // No global Run button: an item shows a play button when the AI has something to run on it (see NodeRow).
    }

    private func badge(_ p: Panel) -> Int {
        let s = Store(ctx)
        switch p {
        case .inbox: return openProposals.count
        // Drafts to review and shared items waiting on you; tap their squares in the outline (or filter by Review).
        case .outline: return s.allNodes().filter { $0.state == .review || $0.isYourTurn }.count
        default: return 0
        }
    }

    @ViewBuilder
    private func panelView(_ p: Panel) -> some View {
        switch p {
        case .outline: OutlineView(sel: sel)
        case .batch: BatchView(sel: sel)
        case .inbox: InboxView(sel: sel)
        case .calendar: CalendarView(sel: sel)
        case .digest: DigestView(sel: sel)
        case .activity: ActivityView()
        case .settings: SettingsView()
        }
    }
}
