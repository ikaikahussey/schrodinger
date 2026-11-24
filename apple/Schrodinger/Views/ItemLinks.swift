import SwiftUI
import SwiftData

// Links between two items: the list of an open item's linked items, and link mode (the whole outline in a modal,
// where items are tapped to link or unlink them).
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

/// Link mode: the whole outline in a modal, in the outline's own form and order (the same marks, colors, indents
/// and rails; every item shown, collapsed or not). Tap an item to link it to the one being linked; tap a linked item
/// to unlink it. The modal stays up until Done, so several items can be linked in one visit. It opens scrolled to the
/// item being linked, which is ringed and cannot be picked.
struct LinkPicker: View {
    /// The item being linked.
    let nodeID: UUID
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Node.position), SortDescriptor(\Node.createdAt)]) private var all: [Node]
    @Query(sort: [SortDescriptor(\Attachment.createdAt)]) private var attachments: [Attachment]
    @State private var search = ""

    /// One line of the outline.
    struct Row: Identifiable {
        let node: Node
        let depth: Int
        /// Ancestors' colors, outermost first (the rails).
        let trail: [Color]
        let color: Color
        let hasChildren: Bool
        var id: UUID { node.id }
    }

    private var terms: [String] { search.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    /// The outline, top to bottom, as the main view orders it. With a search: the items that match, and their
    /// ancestors (so each match keeps its place in the hierarchy).
    private var rows: [Row] {
        let look = Appearance.shared
        let kids = Dictionary(grouping: all, by: { $0.parentID }).mapValues { $0.sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) } }
        let terms = self.terms
        func matches(_ n: Node) -> Bool { let t = n.title.lowercased(); return terms.allSatisfy { t.contains($0) } }
        func subtreeMatches(_ n: Node) -> Bool { matches(n) || (kids[n.id] ?? []).contains { subtreeMatches($0) } }
        var out: [Row] = []
        func walk(_ n: Node, _ depth: Int, _ trail: [Color]) {
            guard depth < 64 else { return }   // a parent loop in bad data must not hang the view
            if !terms.isEmpty && !subtreeMatches(n) { return }
            let children = kids[n.id] ?? []
            let own = look.itemColor(depth: depth, state: n.isProject ? .todo : n.state, assignee: n.isProject ? .human : n.assignee)
            out.append(Row(node: n, depth: depth, trail: trail, color: own, hasChildren: !children.isEmpty))
            for c in children { walk(c, depth + 1, trail + [own]) }
        }
        for top in kids[nil] ?? [] { walk(top, 0, []) }
        return out
    }

    /// The items already linked to this one.
    private var linked: Set<UUID> {
        Set(attachments.filter { $0.kind == .item }.compactMap { $0.otherEnd(from: nodeID) })
    }

    var body: some View {
        let rows = self.rows
        let linked = self.linked
        let files = Dictionary(grouping: attachments.filter { $0.kind != .item }, by: \.nodeID)
        // How many links each item has, for the glyph in its mark.
        let linkCounts = attachments.filter { $0.kind == .item }.reduce(into: [UUID: Int]()) { counts, l in
            counts[l.nodeID, default: 0] += 1
            if let other = l.linkedID { counts[other, default: 0] += 1 }
        }
        let name = all.first { $0.id == nodeID }?.title ?? ""
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text("Tap an item to link it to \u{201C}\(name)\u{201D}. Tap a linked item to unlink it.")
                            .font(Appearance.shared.font.font(.caption)).foregroundStyle(Color.ink.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, StatusBar.margin).padding(.bottom, 8)
                        ForEach(rows) { r in
                            row(r, isLinked: linked.contains(r.id), files: files[r.id] ?? [], itemLinks: linkCounts[r.id] ?? 0)
                                .id(r.id)
                        }
                        if rows.isEmpty {
                            Text(search.isEmpty ? "No items" : "No matches").foregroundStyle(Color.ink.opacity(0.5))
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                    }
                    .padding(.trailing, 16).padding(.top, 8).padding(.bottom, 24)
                }
                .background(Color.canvas)
                // Start where the user was: at the item being linked.
                .onAppear { proxy.scrollTo(nodeID, anchor: .center) }
            }
            .searchable(text: $search, prompt: "Find an item")
            .navigationTitle(linked.isEmpty ? "Link to Item" : linked.count == 1 ? "1 Linked Item" : "\(linked.count) Linked Items")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .sensoryFeedback(.selection, trigger: linked.count)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    /// One outline row: its mark where the outline puts it, its text, and at the right whether it is linked.
    private func row(_ r: Row, isLinked: Bool, files: [Attachment], itemLinks: Int) -> some View {
        let n = r.node
        let isSelf = n.id == nodeID
        let leaf = !n.isProject && !r.hasChildren
        let checkable = n.due != nil && leaf
        let done = n.state == .done && leaf
        let untitled = n.title.trimmingCharacters(in: .whitespaces).isEmpty
        let notes = n.isProject ? n.goal : n.notes
        let indicators = MarkIndicator.present(hasDate: n.due != nil,
                                               hasNotes: !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                               webLinks: files.filter { $0.kind == .link }.count, itemLinks: itemLinks,
                                               photos: files.filter { $0.kind == .photo }.count, checkable: checkable)
        let boxTint: Color = n.state == .todo || n.state == .in_progress || n.state == .done ? .canvas : r.color
        // The item being linked cannot be picked, and neither can an item with no text (it would have no name).
        let pickable = !isSelf && !untitled
        let font = Appearance.shared.font.font(.body)
        let spoken = (untitled ? "New item" : n.title) + (isSelf ? ", this item" : isLinked ? ", linked" : "")
        let hint = !pickable ? "" : isLinked ? "Removes the link" : "Links the two items"
        // Laid out as the outline lays out a row: the middle of the first line of text on the middle of the mark.
        return HStack(alignment: .rowLine, spacing: 0) {
            StatusBar(state: n.state, assignee: n.assignee, isProject: n.isProject, color: r.color, depth: r.depth,
                      indicators: indicators, checkable: checkable)
                .overlay(alignment: .leading) { if checkable { CheckBox(done: n.state == .done, tint: boxTint, action: {}).allowsHitTesting(false) } }
                .overlay { if isSelf { StatusBar.ownShape.strokeBorder(Color.ink, lineWidth: 1.5).padding(-3) } }
                .padding(.leading, StatusBar.margin + StatusBar.indent(r.depth))
                .frame(width: StatusBar.textStart(r.depth), alignment: .leading)
                .padding(.vertical, 4)
                .alignmentGuide(.rowLine) { _ in 4 + StatusBar.h / 2 }
            Text(untitled ? "New item" : n.title)
                .font(n.isProject ? font.weight(.semibold) : font)
                .strikethrough(done)
                .foregroundStyle(untitled ? Color.ink.opacity(0.3) : done ? Color.ink.opacity(0.4) : Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.rowLine) { d in d[.firstTextBaseline] * 0.65 }
            if isSelf {
                Text("THIS ITEM").font(PanelPalette.label(.caption2)).foregroundStyle(Color.ink.opacity(0.55)).padding(.leading, 6)
                    .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
            } else if isLinked {
                Image(systemName: ItemLink.symbol).font(.system(size: 11, weight: .bold))
                    .foregroundStyle(PanelPalette.text(on: PanelPalette.orange))
                    .frame(width: 22, height: 22)
                    .background(PanelPalette.orange, in: Circle())
                    .padding(.leading, 6)
                    .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
            }
        }
        .padding(.vertical, Appearance.shared.rowPadding)
        .background { RailLines(trail: r.trail, own: r.hasChildren ? r.color : nil) }
        .background(isLinked ? PanelPalette.orange.opacity(0.14) : .clear)
        .opacity(isSelf ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if pickable { toggle(n.id, isLinked: isLinked) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint(hint)
        .accessibilityAddTraits(pickable ? .isButton : [])
        .accessibilityAction { if pickable { toggle(n.id, isLinked: isLinked) } }
    }

    private func toggle(_ other: UUID, isLinked: Bool) {
        let store = Store(ctx)
        withAnimation(.snappy(duration: 0.18)) {
            if isLinked { store.unlink(nodeID, other) } else { store.link(nodeID, other) }
            store.save()
        }
    }
}
