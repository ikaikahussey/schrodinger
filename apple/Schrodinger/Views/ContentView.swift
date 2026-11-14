import SwiftUI
import SwiftData

enum Panel: String, CaseIterable, Identifiable {
    case outline, batch, review, inbox, calendar, digest, activity, settings
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .outline: "list.bullet.indent"; case .batch: "square.stack.3d.up"; case .review: "checkmark.rectangle.stack"
        case .inbox: "tray"; case .calendar: "calendar"; case .digest: "doc.text"; case .activity: "clock"; case .settings: "gear"
        }
    }
}

@MainActor
@Observable
final class Selection {
    var nodeID: UUID? = nil
    var panel: Panel = .outline
}

struct ContentView: View {
    @Environment(HarnessEngine.self) private var harness
    @Environment(\.modelContext) private var ctx
    @State private var sel = Selection()
    @State private var runMessage: String? = nil
    @Query(filter: #Predicate<Proposal> { $0.statusRaw == "open" }) private var openProposals: [Proposal]

    var body: some View {
        Group {
            #if os(macOS)
            NavigationSplitView {
                List(selection: Binding(get: { sel.panel }, set: { if let p = $0 { sel.panel = p } })) {
                    ForEach(Panel.allCases.filter { $0 != .settings && $0 != .review }) { p in
                        Label(p.label, systemImage: p.icon).badge(badge(p)).tag(p)
                    }
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 190)
            } content: {
                OutlineView(sel: sel).navigationSplitViewColumnWidth(min: 420, ideal: 620)
            } detail: {
                panelView(sel.panel == .outline ? .review : sel.panel).navigationSplitViewColumnWidth(min: 320, ideal: 420)
            }
            #else
            // Review is not a tab: it is pushed over the outline when an item is opened.
            TabView(selection: Binding(get: { sel.panel == .review ? .outline : sel.panel }, set: { sel.panel = $0 })) {
                ForEach([Panel.outline, .batch, .inbox, .calendar, .settings]) { p in
                    NavigationStack {
                        if p == .outline {
                            OutlineView(sel: sel)
                                .navigationDestination(isPresented: Binding(get: { sel.panel == .review }, set: { if !$0 { sel.panel = .outline } })) { ReviewView(sel: sel) }
                        } else { panelView(p) }
                    }
                    .tabItem { Label(p.label, systemImage: p.icon) }.badge(badge(p)).tag(p)
                }
            }
            #endif
        }
        .environment(sel)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { let r = await harness.runOnce(); runMessage = r.joined(separator: "\n\n") }
                } label: { Label(harness.running ? "Running…" : "Run harness", systemImage: "play.circle") }
                .disabled(harness.running)
            }
        }
        .alert("Harness run", isPresented: Binding(get: { runMessage != nil }, set: { if !$0 { runMessage = nil } })) { Button("OK") {} } message: { Text(runMessage ?? "") }
    }

    private func badge(_ p: Panel) -> Int {
        let s = Store(ctx)
        switch p {
        case .inbox: return openProposals.count
        case .review: return s.allNodes().filter { $0.state == .review || $0.isYourTurn }.count
        default: return 0
        }
    }

    @ViewBuilder
    private func panelView(_ p: Panel) -> some View {
        switch p {
        case .outline: OutlineView(sel: sel)
        case .batch: BatchView(sel: sel)
        case .review: ReviewView(sel: sel)
        case .inbox: InboxView(sel: sel)
        case .calendar: CalendarView(sel: sel)
        case .digest: DigestView(sel: sel)
        case .activity: ActivityView()
        case .settings: SettingsView()
        }
    }
}
