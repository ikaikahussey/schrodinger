import SwiftUI
import SwiftData

/// History: the outline, marked up with what changed lately. Added items are green with a +, deleted items are
/// struck through in the place they used to be, renamed items show their old text struck through before the new,
/// completed items carry a check. Tapping an item that still exists shows it in the outline.
struct HistoryView: View {
    @Environment(\.modelContext) private var ctx
    var sel: Selection
    // Observed so the view refreshes when items or their history change.
    @Query private var nodes: [Node]
    @Query private var entries: [ActivityEntry]
    @AppStorage("historyPeriod") private var period: Period = .week
    @AppStorage("historyChangesOnly") private var changesOnly = false

    enum Period: String, CaseIterable, Identifiable {
        case today, week, month
        var id: String { rawValue }
        var label: String { switch self { case .today: "Today"; case .week: "7 days"; case .month: "30 days" } }
        func start(now: Date = Date()) -> Date {
            switch self {
            case .today: Calendar.current.startOfDay(for: now)
            case .week: now.addingTimeInterval(-7 * 86400)
            case .month: now.addingTimeInterval(-30 * 86400)
            }
        }
    }

    var body: some View {
        let _ = (nodes.count, entries.count)
        let rows = Store(ctx).history(since: period.start(), changesOnly: changesOnly)
        List {
            Section {
                Picker("Period", selection: $period) { ForEach(Period.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                Toggle("Changes only", isOn: $changesOnly)
                Text(Self.summary(rows)).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if rows.isEmpty { Text(changesOnly ? "No changes in this period." : "Nothing here yet.").foregroundStyle(.secondary) }
                ForEach(rows) { r in
                    HistoryLine(row: r)
                        .contentShape(Rectangle())
                        .onTapGesture { if !r.deleted { sel.open(r.id) } }
                }
            }
        }
        .navigationTitle("History")
    }

    /// "3 added · 1 deleted · 2 completed", or "No changes".
    static func summary(_ rows: [HistoryRow]) -> String {
        let parts = HistoryChange.allCases.compactMap { c -> String? in
            let n = rows.filter { $0.changes.contains(c) }.count
            return n == 0 ? nil : "\(n) \(c.rawValue)"
        }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
    }
}

struct HistoryLine: View {
    let row: HistoryRow

    private var added: Bool { row.changes.contains(.added) }
    private var mark: (symbol: String, color: Color)? {
        if row.deleted { return ("minus", .red) }
        if added { return ("plus", .green) }
        if row.changes.contains(.completed) { return ("checkmark", .secondary) }
        if row.changes.contains(.moved) { return ("arrow.turn.down.right", .secondary) }
        if row.changes.contains(.renamed) || row.changes.contains(.edited) { return ("pencil", .secondary) }
        return nil
    }
    private var name: String { row.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : row.title }
    private var text: Text {
        if row.deleted { return Text(name).strikethrough().foregroundStyle(.red) }
        let now = Text(name).strikethrough(row.done).foregroundStyle(added ? Color.green : Color.primary)
        if let old = row.oldTitle { return Text("\(Text(old).strikethrough().foregroundStyle(.secondary)) \(now)") }
        return now
    }
    private var spoken: String {
        let what = HistoryChange.allCases.filter { row.changes.contains($0) }.map(\.rawValue).joined(separator: ", ")
        let was = row.oldTitle.map { ", was \($0)" } ?? ""
        return what.isEmpty ? name : "\(name), \(what)\(was)"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if let m = mark { Image(systemName: m.symbol).foregroundStyle(m.color) } else { Color.clear.frame(height: 1) }
            }
            .font(.caption.weight(.bold)).frame(width: 16)
            text
            Spacer(minLength: 8)
            if !row.changes.isEmpty, let when = row.when {
                Text(when.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        // Items that did not change sit back, so the changes stand out.
        .opacity(row.changes.isEmpty ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}
