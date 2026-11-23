import SwiftUI

// History is a mode of the outline (header menu → History), not a screen of its own. While it is on, the outline
// shows what changed in the chosen period, in place: items added are marked green, items deleted come back as
// struck-through rows where they used to be (each with a Reinstate button), and a renamed item shows its old text
// above it. A bar under the header names the period and has the Done button that leaves the mode.

/// What History mode adds to the outline: a mark for each current item that changed, and the deleted items, by the
/// item they were under.
struct OutlineHistory {
    var marks: [UUID: HistoryRow] = [:]
    var tombs: [UUID?: [HistoryRow]] = [:]
    var summary = "No changes"

    init(_ rows: [HistoryRow]) {
        for r in rows {
            if r.deleted { tombs[r.parentID, default: []].append(r) }
            else if !r.changes.isEmpty { marks[r.id] = r }
        }
        summary = HistoryRow.summary(rows)
    }

    /// An item's children with the deleted ones put back where they were.
    enum Entry: Identifiable {
        case node(Node), tomb(HistoryRow)
        var id: UUID { switch self { case .node(let n): n.id; case .tomb(let t): t.id } }
    }
    func entries(under parent: UUID?, children: [Node]) -> [Entry] {
        var rest = (tombs[parent] ?? [])[...]
        var out: [Entry] = []
        for (i, c) in children.enumerated() {
            while let t = rest.first, t.position <= i { out.append(.tomb(t)); rest.removeFirst() }
            out.append(.node(c))
        }
        out.append(contentsOf: rest.map { Entry.tomb($0) })
        return out
    }
}

/// The bar under the header while History mode is on: the period, what changed, and Done.
struct HistoryBar: View {
    @Binding var period: HistoryPeriod
    let summary: String
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color.ink.opacity(0.6))
            Menu {
                Picker("Period", selection: $period) { ForEach(HistoryPeriod.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.inline)
            } label: {
                pill("HISTORY \u{00B7} " + period.label.uppercased(), systemImage: "chevron.down", fill: PanelPalette.lavender)
            }
            .accessibilityLabel("History period: " + period.label)
            Text(summary).font(Appearance.shared.font.font(.caption)).foregroundStyle(Color.ink.opacity(0.6)).lineLimit(1)
            Spacer(minLength: 4)
            Button(action: onDone) { pill("DONE", systemImage: "xmark", fill: PanelPalette.peach) }
                .help("Leave History")
                .accessibilityLabel("Leave History")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.bottom, 6)
        .background(Color.canvas)
    }

    private func pill(_ text: String, systemImage: String, fill: Color) -> some View {
        HStack(spacing: 4) {
            Text(text).font(PanelPalette.label(.caption)).lineLimit(1)
            Image(systemName: systemImage).font(.system(size: 9, weight: .heavy))
        }
        .foregroundStyle(PanelPalette.text(on: fill))
        .padding(.horizontal, 9).frame(height: 24)
        .background(fill)
        .contentShape(Rectangle())
    }
}

/// A deleted item, shown where it used to be: its text struck through, and a button that brings it back.
struct TombRow: View {
    let row: HistoryRow
    let depth: Int
    let onReinstate: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "minus").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.red)
            Text(row.title).font(Appearance.shared.font.font(.body)).strikethrough().foregroundStyle(Color.red.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onReinstate) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .heavy))
                    Text("REINSTATE").font(PanelPalette.label(.caption)).lineLimit(1)
                }
                .foregroundStyle(PanelPalette.text(on: PanelPalette.peach))
                .padding(.horizontal, 9).frame(height: 24)
                .background(PanelPalette.peach)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Bring this item back")
            .accessibilityLabel("Reinstate " + row.title)
        }
        .padding(.leading, max(0, StatusBar.textStart(depth) - 16))
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Deleted: " + row.title)
    }
}

/// A renamed item's old text, shown struck through above its row.
struct OldTitleRow: View {
    let text: String
    let depth: Int
    var body: some View {
        Text(text).font(Appearance.shared.font.font(.caption)).strikethrough().foregroundStyle(Color.ink.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, StatusBar.textStart(depth)).padding(.top, 2)
            .accessibilityLabel("Was: " + text)
    }
}

/// The mark on an item added in the period: a green wash and a green edge. Touches pass through to the row.
struct AddedMark: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.overlay {
            if on {
                ZStack(alignment: .trailing) {
                    Color.green.opacity(0.13)
                    Rectangle().fill(Color.green).frame(width: 4)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}
