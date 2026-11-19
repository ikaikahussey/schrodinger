import SwiftUI
import SwiftData

// Links between two items: the list of an open item's linked items, and the picker that makes a new link.
// A link has no direction. It is stored once (an `Attachment` of kind `item`) and shows on both items.

/// One linked item, as seen from the item whose row shows it.
struct ItemLink: Identifiable {
    /// The stored link (removing it unlinks both items).
    let link: Attachment
    /// The item on the other end.
    let item: Node
    var id: UUID { link.id }
    /// The glyph for links between items (web links use "link").
    static let symbol = "arrow.left.arrow.right"
}

/// An open item's linked items, one per line under its text: tap a name to go to that item, x to remove the link.
struct ItemLinkList: View {
    let links: [ItemLink]
    let onOpen: (Node) -> Void
    let onRemove: (ItemLink) -> Void

    var body: some View {
        // Reading a deleted model traps; the list can render once more after a link or an item is removed.
        let live = links.filter { !$0.link.isDeleted && $0.link.modelContext != nil && !$0.item.isDeleted && $0.item.modelContext != nil }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(live) { l in
                let name = l.item.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : l.item.title
                HStack(spacing: 2) {
                    Button { onOpen(l.item) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: ItemLink.symbol).font(.system(size: 10, weight: .semibold))
                            Text(name).font(.caption.weight(.medium)).lineLimit(1)
                                .strikethrough(l.item.state == .done)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Color.ink.opacity(0.07), in: Capsule())
                        .foregroundStyle(Color.ink.opacity(l.item.state == .done ? 0.5 : 0.85))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Linked item: " + name).accessibilityHint("Goes to the item")
                    FieldIcon(systemImage: "xmark", width: ItemField.compact) { onRemove(l) }
                        .help("Remove link").accessibilityLabel("Remove link to " + name)
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Choose the item to link to: every other item not already linked, most recently changed first, with a search field.
struct LinkPicker: View {
    let nodeID: UUID
    /// Items already linked (left out of the list).
    let linked: Set<UUID>
    let onPick: (UUID) -> Void
    @Query(sort: [SortDescriptor(\Node.updatedAt, order: .reverse)]) private var all: [Node]
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var results: [Node] {
        let terms = search.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let found = all.filter { n in
            guard n.id != nodeID, !linked.contains(n.id), !n.title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            let text = n.title.lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
        return Array(found.prefix(200))
    }
    /// Where an item sits: its ancestors' titles, outermost first.
    private func path(_ n: Node, _ byID: [UUID: Node]) -> String {
        var names: [String] = []
        var p = n.parentID
        while let id = p, let x = byID[id], names.count < 12 { names.insert(x.title, at: 0); p = x.parentID }
        return names.joined(separator: " \u{203A} ")
    }

    var body: some View {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        NavigationStack {
            List(results) { n in
                Button { onPick(n.id); dismiss() } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.title).foregroundStyle(Color.ink).lineLimit(2)
                        let place = path(n, byID)
                        if !place.isEmpty { Text(place).font(.caption).foregroundStyle(Color.ink.opacity(0.5)).lineLimit(1) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay { if results.isEmpty { Text(search.isEmpty ? "No other items" : "No matches").foregroundStyle(Color.ink.opacity(0.5)) } }
            .searchable(text: $search, prompt: "Find an item")
            .navigationTitle("Link to Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }
}
