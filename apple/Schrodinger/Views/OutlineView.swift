import SwiftUI
import SwiftData

/// One continuous outline. Depth is shown by black bars at the left (one per level). The item's own bar carries
/// its status, who holds it, and its mode; tapping the bars opens the item's menu. Everything else stays out of the
/// way of the text. Top-level items are projects (the harness runs one agent per top-level item).
struct OutlineView: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var sel: Selection
    @Query(sort: [SortDescriptor(\Node.position), SortDescriptor(\Node.createdAt)]) private var all: [Node]
    @State private var filter: Filter = .all
    @State private var modeFilter: Mode? = nil
    @State private var showLegend = false
    @FocusState private var focused: UUID?
    /// Row that should switch to its text field and take focus. Focus can't be set on a field that isn't on screen yet,
    /// so the row shows its field first, then claims focus (see NodeRow.claimEdit).
    @State private var editRequest: UUID?
    @State private var drag = OutlineDrag()
    /// Item the outline is zoomed into (shown at the top with its children), or nil for the whole outline.
    @State private var zoomID: UUID? = nil
    @State private var zoomingIn = true

    enum Filter: String, CaseIterable, Identifiable { case all, mine, ai, review, blocked, week; var id: String { rawValue }
        var label: String { switch self { case .all: "All"; case .mine: "Mine"; case .ai: "AI"; case .review: "Review"; case .blocked: "Blocked"; case .week: "This week" } } }

    private var store: Store { Store(ctx) }
    private var look: Appearance { Appearance.shared }
    private var childrenMap: [UUID?: [Node]] { Dictionary(grouping: all, by: { $0.parentID }).mapValues { $0.sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) } } }

    var body: some View {
        let kids = childrenMap
        let roots = kids[nil] ?? []
        let zoomed = zoomID.flatMap { store.node($0) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let z = zoomed { breadcrumb(z) }
                VStack(alignment: .leading, spacing: 0) {
                    if let z = zoomed {
                        nodeTree(z, depth: 0, kids: kids, trail: [], context: look.contextColor(rootIndex(z, roots: roots)))
                    } else {
                        ForEach(Array(roots.enumerated()), id: \.element.id) { i, p in nodeTree(p, depth: 0, kids: kids, trail: [], context: look.contextColor(i)) }
                    }
                }
                .id(zoomID)
                .transition(.asymmetric(
                    insertion: .scale(scale: zoomingIn ? 0.94 : 1.06, anchor: .top).combined(with: .opacity),
                    removal: .opacity))
                Button {
                    let n = zoomed.map { store.create(parentID: $0.id, position: (kids[$0.id] ?? []).count) } ?? store.create()
                    store.save(); beginEdit(n.id)
                } label: {
                    HStack(spacing: 10) { Image(systemName: "plus").font(.caption.weight(.semibold)); Text("New item").font(look.font.font(.callout)) }
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary).padding(.vertical, 10).padding(.leading, 16)
                if showLegend { BarLegend().padding(.top, 24) }
            }
            // Squares start at the first pixel on the left; text keeps its margin on the right.
            .padding(.trailing, 16).padding(.top, 8)
            .coordinateSpace(name: "outline")
            .onPreferenceChange(RowFrameKey.self) { v in Task { @MainActor in drag.frames = v } }
            .overlay(alignment: .topLeading) {
                if let t = drag.target, drag.id != nil {
                    Rectangle().fill(Color.ink).frame(height: 2)
                        .padding(.leading, CGFloat(t.depth - (zoomed.map(depthOf) ?? 0)) * StatusBar.step).padding(.trailing, 16)
                        .offset(y: t.y - 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .scrollDisabled(drag.id != nil)   // the list holds still while an item is lifted
        // Zoomed in: a quick swipe right anywhere on the page goes back to the whole outline.
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { v in
            if zoomID != nil && drag.id == nil && OutlineView.isBackSwipe(v) { zoom(to: nil) }
        })
        .background(Color.canvas)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                CatLogo().frame(width: 26, height: 26)
                    .accessibilityElement().accessibilityLabel("Schrodinger").accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { ctx.undoManager?.undo(); store.save() } label: { Image(systemName: "arrow.uturn.backward") }.help("Undo")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button { ctx.undoManager?.redo(); store.save() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            }
            if focused != nil || editRequest != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { endEdit() }.fontWeight(.semibold).keyboardShortcut(.escape, modifiers: [])
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { endEdit() }.fontWeight(.semibold)
                }
                #endif
            }
            ToolbarItem(placement: .primaryAction) {
                Button { captureThought(roots: roots) } label: { Image(systemName: "plus") }
                    .help("New thought (goes under “Thoughts”)")
                    .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) { filterMenu }
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation(.snappy(duration: 0.2)) { showLegend.toggle() } } label: { Image(systemName: showLegend ? "info.circle.fill" : "info.circle") }
                    .help(showLegend ? "Hide the square legend" : "Show the square legend")
            }
        }
    }

    private var filtering: Bool { filter != .all || modeFilter != nil }

    /// Filters, in a menu in the navigation bar. The icon fills in while a filter is on.
    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: Binding(get: { filter }, set: { v in withAnimation(.snappy(duration: 0.25)) { filter = v } })) {
                ForEach(Filter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Mode", selection: Binding(get: { modeFilter }, set: { v in withAnimation(.snappy(duration: 0.25)) { modeFilter = v } })) {
                Text("Any mode").tag(Mode?.none)
                ForEach(Mode.allCases) { Text($0.label).tag(Mode?.some($0)) }
            }
            .pickerStyle(.inline)
            if filtering {
                Divider()
                Button(role: .destructive) { withAnimation(.snappy(duration: 0.25)) { filter = .all; modeFilter = nil } } label: { Label("Clear filters", systemImage: "xmark") }
            }
        } label: {
            Image(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help(filtering ? "Filters (on)" : "Filters")
        .accessibilityLabel(filtering ? "Filters, on" : "Filters")
    }

    /// A quick, mostly horizontal swipe to the right: the "go back" gesture. Distinct from the slower row pull that indents.
    nonisolated static func isBackSwipe(_ v: DragGesture.Value) -> Bool {
        let dx = v.translation.width, dy = v.translation.height
        return dx > 60 && abs(dy) < max(50, dx * 0.5) && v.predictedEndTranslation.width - dx > 80
    }

    /// Quick capture: a new item under a top-level "Thoughts" project (created on first use), focused for typing.
    private func captureThought(roots: [Node]) {
        let s = store
        let inbox = roots.first { $0.title.caseInsensitiveCompare("Thoughts") == .orderedSame } ?? {
            let p = s.create(title: "Thoughts", position: 0)
            s.update(p) { $0.goal = "Loose thoughts to sort into projects later." }
            return p
        }()
        if inbox.collapsed { s.update(inbox) { $0.collapsed = false } }
        let n = s.create(parentID: inbox.id, assignee: .human, position: 0)
        s.save()
        if zoomID != nil && zoomID != inbox.id { zoom(to: nil) }
        beginEdit(n.id)
    }
    /// Zoom into an item (nil = whole outline), animated.
    private func zoom(to id: UUID?) {
        endEdit()
        zoomingIn = id.map { target in zoomID.map { isInSubtree(target, of: $0) && target != $0 } ?? true } ?? false
        withAnimation(.snappy(duration: 0.32)) { zoomID = id; sel.nodeID = nil }
    }
    private func rootIndex(_ n: Node, roots: [Node]) -> Int {
        var r = n; while let pid = r.parentID, let p = store.node(pid) { r = p }
        return roots.firstIndex { $0.id == r.id } ?? 0
    }
    /// Path back out: All › ancestors. The zoomed item itself is the first row below.
    private func breadcrumb(_ z: Node) -> some View {
        var path: [Node] = []
        var p = z.parentID
        while let id = p, let x = store.node(id) { path.insert(x, at: 0); p = x.parentID }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { zoom(to: nil) } label: { Label("All", systemImage: "chevron.left").labelStyle(.titleAndIcon) }
                    .keyboardShortcut("[", modifiers: .command)
                ForEach(path) { a in
                    Text("›").foregroundStyle(Color.ink.opacity(0.3))
                    Button(a.title.isEmpty ? "Untitled" : a.title) { zoom(to: a.id) }.lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .font(look.font.font(.footnote, weight: .medium))
            .foregroundStyle(Color.ink.opacity(0.6))
            .padding(.leading, 16).padding(.vertical, 8)
        }
        .transition(.opacity)
    }
    private func beginEdit(_ id: UUID) { sel.nodeID = id; editRequest = id }
    private func endEdit() { editRequest = nil; focused = nil }

    private func matches(_ n: Node) -> Bool {
        if n.isProject { return true }
        if let m = modeFilter, n.mode != m { return false }
        switch filter {
        case .all: return modeFilter == nil || n.state != .done
        case .mine: return (n.assignee == .human || n.isYourTurn) && n.state != .done
        case .ai: return (n.assignee == .ai || (n.assignee == .shared && n.aiStatus == .pending)) && n.state != .done
        case .review: return n.state == .review || n.isYourTurn
        case .blocked: return n.state == .blocked
        case .week: return n.due.map { $0 < Date().addingTimeInterval(7 * 86400) } ?? false && n.state != .done
        }
    }
    private func subtreeMatches(_ n: Node, kids: [UUID?: [Node]]) -> Bool { matches(n) || (kids[n.id] ?? []).contains { subtreeMatches($0, kids: kids) } }

    private func nodeTree(_ n: Node, depth: Int, kids: [UUID?: [Node]], trail: [Color], context: Color) -> AnyView {
        let children = kids[n.id] ?? []
        // Own color: the item's mode, else its project's context color. Children inherit this square in their trail.
        let own = (n.isProject ? nil : n.mode.map { look.color(for: $0) }) ?? context
        let hidden = (filter != .all || modeFilter != nil) && depth > 0 && !subtreeMatches(n, kids: kids)
        if hidden { return AnyView(EmptyView()) }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            NodeRow(node: n, depth: depth, trail: trail, color: own, hasChildren: !children.isEmpty, leafCount: leafCount(n, kids: kids), sel: sel, focused: $focused, editRequest: $editRequest, drag: drag,
                    onKey: { key in handleKey(key, n, kids: kids) },
                    onDragChanged: { dx, dy in updateDropTarget(n, dx: dx, dy: dy) },
                    onDrop: { performDrop(n) },
                    onZoom: { zoom(to: n.id == zoomID ? n.parentID : n.id) },
                    swipeBack: zoomID != nil)
            if n.isProject { ProjectLine(node: n, progress: store.progress(of: n.id)) }
            if !n.collapsed || n.id == zoomID {
                ForEach(children) { c in nodeTree(c, depth: depth + 1, kids: kids, trail: trail + [own], context: context) }
            }
            if depth == 0 { Spacer().frame(height: 14) }
        })
    }

    private func leafCount(_ n: Node, kids: [UUID?: [Node]]) -> (done: Int, total: Int) {
        let c = kids[n.id] ?? []
        if c.isEmpty { return (n.state == .done ? 1 : 0, 1) }
        return c.map { leafCount($0, kids: kids) }.reduce((0, 0)) { ($0.0 + $1.done, $0.1 + $1.total) }
    }

    // MARK: Drag anywhere

    private func depthOf(_ n: Node) -> Int { var d = 0; var p = n.parentID; while let id = p, let x = store.node(id) { d += 1; p = x.parentID }; return d }
    private func isInSubtree(_ id: UUID, of root: UUID) -> Bool { var p: UUID? = id; while let x = p { if x == root { return true }; p = store.node(x)?.parentID }; return false }

    /// Rows currently laid out, top to bottom, excluding the dragged item and its descendants.
    private func visibleOrder(excluding root: UUID) -> [(node: Node, frame: CGRect, depth: Int)] {
        drag.frames.compactMap { id, f in store.node(id).map { ($0, f, 0) } }
            .filter { !isInSubtree($0.0.id, of: root) }
            .sorted { $0.1.minY < $1.1.minY }
            .map { ($0.0, $0.1, depthOf($0.0)) }
    }

    private func updateDropTarget(_ n: Node, dx: CGFloat, dy: CGFloat) {
        if n.id == zoomID { drag.target = nil; return }   // the zoomed item stays put
        guard let own = drag.origin ?? drag.frames[n.id] else { return }
        let y = own.midY + dy
        let rows = visibleOrder(excluding: n.id)
        // Insertion point: before the first row whose middle is below the finger.
        var idx = rows.firstIndex { $0.frame.midY > y } ?? rows.count
        if zoomID != nil { idx = max(idx, 1) }   // zoomed: nothing can go above the zoomed item
        let above = idx > 0 && idx <= rows.count ? rows[idx - 1] : nil
        let below = idx < rows.count ? rows[idx] : nil
        let lineY = above.map { $0.frame.maxY } ?? below.map { $0.frame.minY } ?? own.minY
        let maxD = (above?.depth ?? -1) + 1
        let minD = below?.depth ?? 0
        let want = (above?.depth ?? 0) + Int((dx / 44).rounded())
        var depth = max(min(minD, maxD), min(maxD, want))
        if let z = zoomID.flatMap({ store.node($0) }) { depth = max(depth, depthOf(z) + 1) }
        let target = OutlineDrag.Target(y: lineY, depth: depth, aboveID: above?.node.id)
        if let old = drag.target {
            if old.depth != depth { Xylophone.shared.play(OutlinePitch.depth(depth)) }
            else if old.aboveID != target.aboveID { Xylophone.shared.play(OutlinePitch.row(idx)) }
        }
        drag.target = target
    }

    private func performDrop(_ n: Node) {
        defer { drag.target = nil; drag.id = nil; drag.origin = nil }
        guard let t = drag.target else { return }
        let s = store
        guard let aboveID = t.aboveID, let above = s.node(aboveID) else { try? s.move(n, to: nil, position: 0); s.save(); return }
        let aboveDepth = depthOf(above)
        if t.depth > aboveDepth {
            try? s.move(n, to: above.id, position: 0)
            if above.collapsed { s.update(above) { $0.collapsed = false } }
        } else {
            var anc = above
            for _ in 0..<(aboveDepth - t.depth) { guard let pid = anc.parentID, let p = s.node(pid) else { break }; anc = p }
            let sibs = s.children(of: anc.parentID).filter { $0.id != n.id }
            let idx = (sibs.firstIndex(where: { $0.id == anc.id }) ?? (sibs.count - 1)) + 1
            try? s.move(n, to: anc.parentID, position: idx)
        }
        s.save()
    }

    enum Key { case enter, tab, shiftTab, backspaceEmpty, altUp, altDown }
    private func handleKey(_ key: Key, _ n: Node, kids: [UUID?: [Node]]) {
        let s = store
        // Moves keep editing only if the item was being edited (strip buttons move without opening the keyboard).
        let wasEditing = focused == n.id || editRequest == n.id
        func keep() { if wasEditing { beginEdit(n.id) } }
        switch key {
        case .enter:
            let created: Node
            if n.id == zoomID || (!(kids[n.id] ?? []).isEmpty && !n.collapsed) { created = s.create(parentID: n.id, position: 0) }
            else { created = s.create(parentID: n.parentID, assignee: n.isProject ? nil : n.assignee, position: n.position + 1) }
            s.save(); beginEdit(created.id)
        case .tab:
            let siblings = kids[n.parentID] ?? []
            guard let idx = siblings.firstIndex(where: { $0.id == n.id }), idx > 0 else { return }
            try? s.move(n, to: siblings[idx - 1].id, position: 999); s.save(); keep()
            Xylophone.shared.play(OutlinePitch.depth(depthOf(n)))
        case .shiftTab:
            guard let pid = n.parentID, let parent = s.node(pid) else { return }
            try? s.move(n, to: parent.parentID, position: parent.position + 1); s.save(); keep()
            Xylophone.shared.play(OutlinePitch.depth(depthOf(n)))
        case .backspaceEmpty:
            guard (kids[n.id] ?? []).isEmpty else { return }
            let siblings = kids[n.parentID] ?? []
            let idx = siblings.firstIndex(where: { $0.id == n.id }) ?? 0
            editRequest = nil; focused = nil
            if sel.nodeID == n.id { sel.nodeID = nil }
            s.delete(n); s.save()
            if idx > 0 { beginEdit(siblings[idx - 1].id) }
        case .altUp, .altDown:
            let siblings = kids[n.parentID] ?? []
            guard let idx = siblings.firstIndex(where: { $0.id == n.id }) else { return }
            let to = key == .altUp ? idx - 1 : idx + 1
            guard to >= 0, to < siblings.count else { return }
            try? s.move(n, to: n.parentID, position: max(0, n.position + (key == .altUp ? -1 : 1))); s.save(); keep()
            Xylophone.shared.play(OutlinePitch.position(to, depth: depthOf(n)))
        }
    }
}

@Observable @MainActor final class OutlineDrag {
    struct Target: Equatable { var y: CGFloat; var depth: Int; var aboveID: UUID? }
    var id: UUID? = nil
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var frames: [UUID: CGRect] = [:]
    /// The lifted row's frame at the moment it was lifted. Its live frame includes the drag offset, so it can't be used.
    var origin: CGRect? = nil
    var target: Target? = nil
}

struct RowFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Hairline progress under a top-level item.
struct ProjectLine: View {
    let node: Node
    let progress: Store.Progress
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.ink.opacity(0.08))
                Rectangle().fill(Color.ink).frame(width: g.size.width * CGFloat(progress.pct) / 100)
            }
        }
        .frame(height: 1.5)
        .padding(.leading, StatusBar.step + 8).padding(.trailing, 4).padding(.bottom, 4)
        .opacity(progress.total == 0 ? 0 : 1)
    }
}

// MARK: - Squares

/// The item's own square: the rightmost square in the row, with rounded top-right and bottom-right corners.
/// Color = the item's mode (or, with no mode, its project's context color). Fill encodes state, inner gaps encode who holds it:
///   state:    todo/in progress/done = solid · review = hollow · blocked = dashed outline
///   assignee: human = whole square · ai = horizontal gap · shared = vertical gap · unassigned = lower half empty
struct StatusBar: View {
    let state: TaskState
    let assignee: Assignee
    let isProject: Bool
    var color: Color = .ink
    /// Side of each square.
    static let h: CGFloat = 16
    static let w: CGFloat = 16
    /// Horizontal distance from one depth square to the next (side + 1 px gap).
    static let step: CGFloat = w + 1
    static var ownShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: h / 2, topTrailingRadius: h / 2, style: .continuous)
    }

    var body: some View {
        let shape = Self.ownShape
        ZStack {
            if isProject {
                shape.fill(color)
            } else {
                switch state {
                case .review:  shape.strokeBorder(color, lineWidth: 2)
                case .blocked: shape.strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                default:       shape.fill(color)
                }
                switch assignee {
                case .human: EmptyView()
                case .ai: Rectangle().fill(Color.canvas).frame(height: 1.5).offset(y: -Self.h * 0.1)
                case .shared: Rectangle().fill(Color.canvas).frame(width: 1.5)
                case .unassigned: Rectangle().fill(Color.canvas).frame(height: Self.h / 2).frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .frame(width: Self.w, height: Self.h)
        .clipShape(shape)
    }
}

/// One square per depth level, flush with the left edge and 1 px apart: each ancestor's square in that ancestor's color,
/// then the item's own square (StatusBar). Tap = actions.
struct DepthBars: View {
    let node: Node
    let depth: Int
    let hasChildren: Bool
    var trail: [Color] = []
    var color: Color = .ink
    var body: some View {
        HStack(alignment: .top, spacing: 1) {
            ForEach(0..<max(depth, 0), id: \.self) { i in
                Rectangle().fill(i < trail.count ? trail[i] : Color.ink).frame(width: StatusBar.w, height: StatusBar.h)
            }
            StatusBar(state: node.state, assignee: node.assignee, isProject: node.isProject, color: color)
        }
        .frame(minWidth: CGFloat(depth + 1) * StatusBar.step, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension VerticalAlignment {
    /// Row alignment: middle of the bars = middle of the first line of text.
    private enum RowLine: AlignmentID { static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] } }
    static var rowLine: VerticalAlignment { VerticalAlignment(RowLine.self) }
}

extension Assignee {
    /// Strip icon for who holds the item.
    var icon: String {
        switch self { case .human: "person.fill"; case .ai: "sparkles"; case .shared: "person.2.fill"; case .unassigned: "person.slash" }
    }
}

extension TaskState {
    /// Strip icon for the item's status.
    var icon: String {
        switch self {
        case .unset: "circle.dashed"; case .todo: "circle"; case .in_progress: "circle.lefthalf.filled"; case .blocked: "exclamationmark.octagon"
        case .review: "eye"; case .done: "checkmark.circle.fill"
        }
    }
}

extension Mode {
    /// Emoji shown under the bars and in menus.
    var emoji: String {
        switch self {
        case .call: "📞"; case .errand: "🚗"; case .email: "✉️"; case .write: "✍️"; case .research: "🔎"; case .meeting: "👥"; case .admin: "🗂️"; case .other: "📌"
        }
    }
    /// Emoji plus name, for menus and pickers.
    var label: String { "\(emoji) \(rawValue)" }
}

struct BarLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Squares").font(.caption.weight(.semibold)).foregroundStyle(Color.ink.opacity(0.6))
            row(StatusBar(state: .todo, assignee: .human, isProject: false), "me")
            row(StatusBar(state: .todo, assignee: .ai, isProject: false), "ai")
            row(StatusBar(state: .todo, assignee: .shared, isProject: false), "both")
            row(StatusBar(state: .todo, assignee: .unassigned, isProject: false), "unassigned")
            row(StatusBar(state: .review, assignee: .human, isProject: false), "review")
            row(StatusBar(state: .blocked, assignee: .human, isProject: false), "blocked")
            Text("Color is the mode; items without a mode take their project's color.").font(.caption2).foregroundStyle(Color.ink.opacity(0.5)).padding(.top, 4)
            ForEach(Mode.allCases) { m in
                row(StatusBar(state: .todo, assignee: .human, isProject: false, color: Appearance.shared.color(for: m)), m.label)
            }
        }
        .padding(.leading, 16)
    }
    private func row(_ bar: StatusBar, _ label: String) -> some View {
        HStack(spacing: 10) { bar; Text(label).font(.caption2).foregroundStyle(Color.ink.opacity(0.6)) }
    }
}

// MARK: - Row

struct NodeRow: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var node: Node
    let depth: Int
    var trail: [Color] = []
    var color: Color = .ink
    let hasChildren: Bool
    let leafCount: (done: Int, total: Int)
    var sel: Selection
    var focused: FocusState<UUID?>.Binding
    @Binding var editRequest: UUID?
    let drag: OutlineDrag
    let onKey: (OutlineView.Key) -> Void
    let onDragChanged: (CGFloat, CGFloat) -> Void
    let onDrop: () -> Void
    var onZoom: () -> Void = {}
    /// The page handles a quick right swipe as "back" (zoomed in), so the row must not also indent on it.
    var swipeBack = false
    @State private var title: String = ""
    @State private var pull: CGFloat = 0
    @GestureState private var handleActive = false
    private var lifting: Bool { drag.id == node.id }
    @State private var note: String = ""
    @State private var showNote = false
    @FocusState private var noteFocused: Bool
    private let pullThreshold: CGFloat = 56

    private var store: Store { Store(ctx) }
    private var titleFont: Font { Appearance.shared.font.font(node.isProject ? .title3 : .body, weight: node.isProject ? .semibold : .regular) }
    private var isLeafTask: Bool { !node.isProject && !hasChildren }
    /// Tap on an unselected row selects it (action strip appears); tap on the selected row deselects it (strip hides).
    private func toggleSelect() {
        withAnimation(.easeOut(duration: 0.15)) { sel.nodeID = sel.nodeID == node.id ? nil : node.id }
    }
    private var done: Bool { node.state == .done && isLeafTask }
    private var editing: Bool { focused.wrappedValue == node.id || editRequest == node.id }
    private func startEdit() {
        commit(); sel.nodeID = node.id
        if editRequest == node.id { claimEdit() } else { editRequest = node.id }   // field appears, then its onAppear claims focus
    }
    /// Called once the text field is on screen: move focus into it (retry once in case the field isn't focusable yet).
    private func claimEdit() {
        let id = node.id
        Task { @MainActor in
            await Task.yield()
            focused.wrappedValue = id
            try? await Task.sleep(for: .milliseconds(150))
            if editRequest == id && focused.wrappedValue != id { focused.wrappedValue = id }
        }
    }
    private func endEdit() { editRequest = nil; focused.wrappedValue = nil }
    private func toggleChildren() { store.update(node) { $0.collapsed.toggle() }; store.save() }

    /// SwiftData traps when a deleted model's attributes are read, and a row can be re-rendered once more after its node
    /// is deleted (before @Query drops it). Render nothing for a deleted node.
    private var gone: Bool { node.isDeleted || node.modelContext == nil }

    var body: some View {
        if gone { EmptyView() } else { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .rowLine, spacing: 10) {
            DepthBars(node: node, depth: depth, hasChildren: hasChildren, trail: trail, color: color)
                .padding(.vertical, 4).padding(.trailing, 4)   // wider grab area
                .contentShape(Rectangle())
                .onTapGesture { commit(); onZoom() }
                .gesture(handleGesture)
                .alignmentGuide(.rowLine) { _ in 4 + StatusBar.h / 2 }   // middle of the bars
                .help(summary + " · tap to zoom in · long-press for actions · hold and drag to move")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { commit(); onZoom() }
                .accessibilityAction(named: "Actions") { commit(); toggleSelect() }

            VStack(alignment: .leading, spacing: 2) {
            // Tap zooms into the item; long press shows the action strip (again hides it); double-tap edits the text.
            if !editing {
                Text(title.isEmpty ? "New item" : title)
                    .font(titleFont)
                    .strikethrough(done)
                    .foregroundStyle(title.isEmpty ? Color.ink.opacity(0.3) : done ? Color.ink.opacity(0.4) : Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEdit() }
                    .onTapGesture { commit(); onZoom() }
                    .onLongPressGesture(minimumDuration: 0.35) { commit(); toggleSelect() }
            } else {
            TextField("", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(titleFont)
                .strikethrough(done)
                .foregroundStyle(done ? Color.ink.opacity(0.4) : Color.ink)
                .focused(focused, equals: node.id)
                .onAppear { if editRequest == node.id { claimEdit() } }
                // Return always makes a new item (the field is multi-line, so a typed newline is caught here too).
                .onChange(of: title) { _, v in if v.contains("\n") { title = v.replacingOccurrences(of: "\n", with: " "); commit(); onKey(.enter) } }
                .onSubmit { commit(); onKey(.enter) }
                #if os(macOS)
                .onKeyPress(.tab) { commit(); onKey(.tab); return .handled }
                .onKeyPress(.tab, phases: .down) { press in if press.modifiers.contains(.shift) { commit(); onKey(.shiftTab); return .handled }; return .ignored }
                .onKeyPress(.delete) { if title.isEmpty { onKey(.backspaceEmpty); return .handled }; return .ignored }
                .onKeyPress(.upArrow, phases: .down) { p in if p.modifiers.contains(.option) { commit(); onKey(.altUp); return .handled }; return .ignored }
                .onKeyPress(.downArrow, phases: .down) { p in if p.modifiers.contains(.option) { commit(); onKey(.altDown); return .handled }; return .ignored }
                .onKeyPress(.return, phases: .down) { p in if p.modifiers.contains(.shift) { commit(); openNote(); return .handled }; return .ignored }
                #endif
            }
            if showNote && !node.isProject {
                TextField("Add context…", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Appearance.shared.font.font(.callout))
                    .foregroundStyle(Color.ink.opacity(0.6))
                    .focused($noteFocused)
                    .onChange(of: noteFocused) { _, f in if !f { commitNote() } }
                    .onSubmit { commitNote(); startEdit() }
            }
            }
            // Middle of the first line of text lines up with the middle of the bars.
            .alignmentGuide(.rowLine) { d in d[.firstTextBaseline] * 0.65 }
            Spacer(minLength: 6)
            marker.alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
            if hasChildren {
                Button { commit(); toggleChildren() } label: {
                    Image(systemName: node.collapsed ? "plus.square" : "minus.square")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.ink)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
                .help(node.collapsed ? "Show children" : "Hide children")
                .accessibilityLabel(node.collapsed ? "Show children" : "Hide children")
            }
            Button { commit(); sel.nodeID = node.id; sel.panel = .review } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink.opacity(0.3))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
            .help("Details")
            .accessibilityLabel("Details")
        }
        .padding(.vertical, 6)
        .onAppear { title = node.title; note = node.notes; showNote = !node.notes.isEmpty }
        .onChange(of: node.title) { _, v in if v != title { title = v } }
        .onChange(of: node.notes) { _, v in if v != note { note = v; if !v.isEmpty { showNote = true } } }
        .onChange(of: handleActive) { _, active in if !active { finishDrag() } }
        .sensoryFeedback(.impact(weight: .medium), trigger: lifting) { _, now in now }
        .onChange(of: focused.wrappedValue) { old, new in
            if new == node.id { sel.nodeID = node.id; if editRequest == node.id { editRequest = nil } }
            if old == node.id && new != node.id { commit() }
        }
        if sel.nodeID == node.id || editing { actionStrip.padding(.leading, CGFloat(depth) * StatusBar.step + 4).padding(.bottom, 8).transition(.opacity) }
        }
        .background(sel.nodeID == node.id ? Color.ink.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .background(GeometryReader { g in Color.clear.preference(key: RowFrameKey.self, value: [node.id: g.frame(in: .named("outline"))]) })
        .offset(x: pull + (lifting ? drag.dx * 0.3 : 0), y: lifting ? drag.dy : 0)
        .background(Color.canvas.opacity(lifting ? 1 : 0), in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(lifting ? 0.18 : 0), radius: lifting ? 8 : 0, y: 2)
        .opacity(lifting ? 0.92 : 1)
        .zIndex(lifting ? 1 : 0)
        // Arrows sit at fixed edges: ← outdent on the left, → indent on the right. Pull toward an arrow to use it.
        .overlay(alignment: .leading) { pullArrow("arrow.left", active: pull < -pullThreshold, show: pull < -8).offset(x: 4) }
        .overlay(alignment: .trailing) { pullArrow("arrow.right", active: pull > pullThreshold, show: pull > 8).offset(x: 4) }
        .simultaneousGesture(pullGesture)
        .contextMenu { menu }
    }

    /// Pull to move: drag the row left to outdent (←), right to indent (→). The text moves the way it will land.
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { v in
                guard abs(v.translation.width) > abs(v.translation.height) * 1.2 else { return }
                var x = v.translation.width
                if node.isProject && x < 0 { x = 0 }
                pull = max(-pullThreshold * 1.6, min(pullThreshold * 1.6, x * 0.6))
            }
            .onEnded { v in
                let p = pull
                withAnimation(.snappy(duration: 0.22)) { pull = 0 }
                if swipeBack && OutlineView.isBackSwipe(v) { return }   // the page goes back instead
                if p < -pullThreshold { commit(); onKey(.shiftTab) }
                else if p > pullThreshold { commit(); onKey(.tab) }
            }
    }

    /// The bars are the handle: press and hold (0.25 s), then drag to move the item anywhere in the outline; horizontal
    /// position while dragging picks the depth at the drop point. The hold keeps ordinary swipes scrolling the list, and
    /// movement is measured in global coordinates so the lifted row's own offset doesn't feed back into the drag.
    private var handleGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($handleActive) { v, active, _ in if case .second(true, _) = v { active = true } }
            .onChanged { v in
                guard case .second(true, let d) = v else { return }
                if drag.id == nil { pull = 0; commit(); drag.origin = drag.frames[node.id]; drag.id = node.id; drag.dx = 0; drag.dy = 0 }
                guard let d else { return }
                drag.dx = d.translation.width; drag.dy = d.translation.height
                onDragChanged(drag.dx, drag.dy)
            }
    }
    /// Ends a lift whether the gesture finished or was cancelled (GestureState resets in both cases; onEnded does not
    /// run on cancel, which used to leave the row stuck lifted).
    private func finishDrag() {
        guard drag.id == node.id else { return }
        // Held and released without moving: a long-tap, which shows the action strip instead of moving the item.
        let still = abs(drag.dx) < 6 && abs(drag.dy) < 6
        drag.dx = 0; drag.dy = 0
        if still { drag.target = nil; onDrop(); toggleSelect(); return }
        withAnimation(.snappy(duration: 0.22)) { onDrop() }
    }

    private func pullArrow(_ name: String, active: Bool, show: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: active ? .bold : .regular))
            .foregroundStyle(active ? Color.ink : Color.ink.opacity(0.35))
            .padding(6)
            .background(Color.canvas.opacity(0.9), in: Circle())
            .opacity(show ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var summary: String {
        if node.isProject { return "Project" }
        var parts = [node.state.label, node.assignee.label]
        if let m = node.mode { parts.append(m.rawValue) }
        if node.isYourTurn { parts.append("your turn") }
        return parts.joined(separator: " · ")
    }

    /// Right edge: due date, "your turn", or counts for a parent. The bars carry everything else.
    @ViewBuilder private var marker: some View {
        if hasChildren && !node.isProject {
            Text("\(leafCount.done)/\(leafCount.total)").font(.caption2.monospacedDigit()).foregroundStyle(Color.ink.opacity(0.4))
        } else if !node.isProject {
            HStack(spacing: 8) {
                if let due = node.due, node.state != .done {
                    Text(due.formatted(.dateTime.month(.abbreviated).day())).font(.caption2).foregroundStyle(due < Date() ? Color.red : Color.ink.opacity(0.45))
                }
                if node.isYourTurn && node.state != .done { Dot(label: "your turn", filled: true) }
            }
        }
    }

    /// The item's actions, on screen (shown under the selected row), as icons only; the current value shows in the icon. Related choices are grouped into menus:
    /// responsible, status, mode, move, and more (context, details, delete). Edit and add stay one tap.
    @ViewBuilder private var actionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if editing {
                    Pill(systemImage: "checkmark", on: true) { commit(); endEdit() }.help("Finish editing").accessibilityLabel("Done")
                } else {
                    Pill(systemImage: "pencil") { startEdit() }.help("Edit text").accessibilityLabel("Edit")
                }
                if !node.isProject {
                    PillMenu(systemImage: node.assignee.icon, title: nil) {
                        Picker("Responsible", selection: assigneeBinding) { ForEach(Assignee.allCases) { Text($0.label).tag($0) } }.pickerStyle(.inline)
                    }.help("Responsible: " + node.assignee.label).accessibilityLabel("Responsible: " + node.assignee.label)
                    PillMenu(systemImage: node.state.icon, title: nil) {
                        Picker("Status", selection: stateBinding) { ForEach(TaskState.allCases) { Text($0 == .in_progress ? "doing" : $0.label).tag($0) } }.pickerStyle(.inline)
                    }.help("Status: " + node.state.label).accessibilityLabel("Status: " + node.state.label)
                    PillMenu(systemImage: node.mode == nil ? "tag" : nil, title: node.mode?.emoji) {
                        Picker("Mode", selection: modeBinding) { Text("none").tag(Mode?.none); ForEach(Mode.allCases) { Text($0.label).tag(Mode?.some($0)) } }.pickerStyle(.inline)
                    }.help("Mode: " + (node.mode?.rawValue ?? "none")).accessibilityLabel("Mode: " + (node.mode?.rawValue ?? "none"))
                }
                PillMenu(systemImage: "arrow.up.and.down.and.arrow.left.and.right", title: nil) {
                    Button { onKey(.altUp) } label: { Label("Move up", systemImage: "arrow.up") }
                    Button { onKey(.altDown) } label: { Label("Move down", systemImage: "arrow.down") }
                    if !node.isProject {
                        Button { onKey(.tab) } label: { Label("Indent", systemImage: "arrow.right") }
                        Button { onKey(.shiftTab) } label: { Label("Outdent", systemImage: "arrow.left") }
                    }
                }.help("Move").accessibilityLabel("Move")
                Pill(systemImage: "plus") { onKey(.enter) }.help("Add item below").accessibilityLabel("Add item below")
                PillMenu(systemImage: "ellipsis", title: nil) {
                    if !node.isProject { Button { openNote() } label: { Label(showNote ? "Edit context" : "Add context", systemImage: "text.alignleft") } }
                    Button { sel.nodeID = node.id; sel.panel = .review } label: { Label("Details", systemImage: "info.circle") }
                    Divider()
                    Button(role: .destructive) { deleteItem() } label: { Label("Delete", systemImage: "trash") }
                }.help("More").accessibilityLabel("More")
            }
            .padding(.vertical, 2)
        }
    }
    // Bindings for the strip pickers; they write through the store so undo and save work.
    private var assigneeBinding: Binding<Assignee> { Binding(get: { node.assignee }, set: { v in store.update(node) { $0.assignee = v }; store.save() }) }
    private var stateBinding: Binding<TaskState> { Binding(get: { node.state }, set: { v in store.update(node) { $0.state = v }; store.save() }) }
    private var modeBinding: Binding<Mode?> { Binding(get: { node.mode }, set: { v in store.update(node) { $0.mode = v }; store.save() }) }

    @ViewBuilder private var menu: some View {
        if !node.isProject {
            Section("Responsible") {
                ForEach(Assignee.allCases) { a in
                    Button { store.update(node) { $0.assignee = a }; store.save() } label: { if node.assignee == a { Label(a.label, systemImage: "checkmark") } else { Text(a.label) } }
                }
            }
            Menu("Mode") {
                Button { store.update(node) { $0.mode = nil }; store.save() } label: { if node.mode == nil { Label("none", systemImage: "checkmark") } else { Text("none") } }
                ForEach(Mode.allCases) { m in
                    Button { store.update(node) { $0.mode = m }; store.save() } label: { if node.mode == m { Label(m.label, systemImage: "checkmark") } else { Text(m.label) } }
                }
            }
            Menu("Status") {
                ForEach(TaskState.allCases) { st in
                    Button { store.update(node) { $0.state = st }; store.save() } label: { if node.state == st { Label(st.label, systemImage: "checkmark") } else { Text(st.label) } }
                }
            }
            Divider()
        }
        Button { startEdit() } label: { Label("Edit text", systemImage: "pencil") }
        if hasChildren { Button(node.collapsed ? "Show children" : "Hide children") { toggleChildren() } }
        if !node.isProject {
            ControlGroup {
                Button { onKey(.shiftTab) } label: { Label("Outdent", systemImage: "arrow.left") }
                Button { onKey(.tab) } label: { Label("Indent", systemImage: "arrow.right") }
            }
        }
        Button("Move up") { onKey(.altUp) }
        Button("Move down") { onKey(.altDown) }
        Button("Add item below") { onKey(.enter) }
        if !node.isProject { Button(showNote ? "Edit context" : "Add context") { openNote() } }
        Divider()
        Button("Details") { sel.nodeID = node.id; sel.panel = .review }
        Button("Delete", role: .destructive) { deleteItem() }
    }

    private func openNote() { showNote = true; DispatchQueue.main.async { noteFocused = true } }
    /// Clear focus and selection first so nothing reads the node after it is gone, then delete.
    private func deleteItem() {
        endEdit(); noteFocused = false
        if sel.nodeID == node.id { sel.nodeID = nil }
        store.delete(node); store.save()
    }
    private func commitNote() {
        guard !gone else { return }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if n != node.notes { store.update(node) { $0.notes = n }; store.save() }
        note = n
        if n.isEmpty { showNote = false }
    }

    private func commit() {
        guard !gone else { return }
        var t = title.trimmingCharacters(in: .whitespaces)
        var assignee: Assignee? = nil, mode: Mode? = nil, clearMode = false
        if let r = t.range(of: "\\s*@(ai|me|human|both|shared|none)\\b", options: [.regularExpression, .caseInsensitive]) {
            let tag = t[r].trimmingCharacters(in: .whitespaces).dropFirst().lowercased()
            assignee = ["ai": .ai, "me": .human, "human": .human, "both": .shared, "shared": .shared, "none": .unassigned][String(tag)]
            t.removeSubrange(r)
        }
        if let r = t.range(of: "\\s*#([a-z]+)\\b", options: [.regularExpression, .caseInsensitive]) {
            let tag = String(t[r].trimmingCharacters(in: .whitespaces).dropFirst().lowercased())
            if let m = Mode(rawValue: tag) { mode = m; t.removeSubrange(r) } else if tag == "none" { clearMode = true; t.removeSubrange(r) }
        }
        t = t.trimmingCharacters(in: .whitespaces)
        if t != node.title || assignee != nil || mode != nil || clearMode {
            store.update(node) { n in n.title = t; if let a = assignee, !n.isProject { n.assignee = a }; if let m = mode { n.mode = m }; if clearMode { n.mode = nil } }
            store.save(); title = t
        }
    }
}

struct Dot: View {
    let label: String
    let filled: Bool
    var body: some View {
        HStack(spacing: 4) {
            Circle().strokeBorder(Color.ink, lineWidth: 1).background(Circle().fill(filled ? Color.ink : .clear)).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(Color.ink.opacity(0.6))
        }
    }
}

/// Capsule look shared by on-screen actions and menus: optional symbol, optional text; `on` = filled.
struct PillLabel: View {
    var systemImage: String? = nil
    var title: String? = nil
    var on = false
    var chevron = false
    var body: some View {
        HStack(spacing: 4) {
            if let i = systemImage { Image(systemName: i).font(.system(size: 11, weight: .semibold)) }
            if let t = title { Text(t).font(.caption.weight(.medium)).lineLimit(1) }
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.5) }
        }
        .padding(.horizontal, title == nil ? 8 : 10).padding(.vertical, 6)
        .frame(minWidth: 30, minHeight: 28)
        .background(on ? Color.ink : Color.ink.opacity(0.06), in: Capsule())
        .foregroundStyle(on ? Color.canvas : Color.ink.opacity(0.8))
        .contentShape(Capsule())
    }
}

/// Small on-screen action: text or symbol (or both); `on` = filled.
struct Pill: View {
    var text: String? = nil
    var systemImage: String? = nil
    var on = false
    let action: () -> Void
    init(_ text: String, on: Bool = false, action: @escaping () -> Void) { self.text = text; self.on = on; self.action = action }
    init(systemImage: String, title: String? = nil, on: Bool = false, action: @escaping () -> Void) { self.systemImage = systemImage; self.text = title; self.on = on; self.action = action }
    var body: some View {
        Button(action: action) { PillLabel(systemImage: systemImage, title: text, on: on) }
            .buttonStyle(.plain)
    }
}

/// A pill that opens a menu of related choices.
struct PillMenu<Content: View>: View {
    var systemImage: String?
    var title: String?
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu { content() } label: { PillLabel(systemImage: systemImage, title: title) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// The app's mark: a cat head, left half solid with an open eye, right half outline with a closed eye.
/// Drawn from the same 64×64 geometry as public/logo.svg; follows light/dark appearance.
struct CatLogo: View {
    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 64
            ctx.translateBy(x: (size.width - 64 * k) / 2, y: (size.height - 64 * k) / 2)
            ctx.scaleBy(x: k, y: k)
            let ink = GraphicsContext.Shading.color(Color.primary)
            let paper = GraphicsContext.Shading.color(Color.canvas)
            let head = Self.head
            let left = Path(CGRect(x: 0, y: 0, width: 32, height: 64)), right = Path(CGRect(x: 32, y: 0, width: 32, height: 64))
            var l = ctx; l.clip(to: left)
            l.fill(head, with: ink)
            l.fill(Path(ellipseIn: CGRect(x: 19.8, y: 34, width: 6.4, height: 8)), with: paper)
            l.fill(Path(ellipseIn: CGRect(x: 21.7, y: 36.7, width: 2.6, height: 2.6)), with: ink)
            l.fill(Self.nose, with: paper)
            var r = ctx; r.clip(to: right)
            r.stroke(head, with: ink, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
            r.fill(Self.nose, with: ink)
            var eye = Path(); eye.move(to: CGPoint(x: 37, y: 38)); eye.addQuadCurve(to: CGPoint(x: 45, y: 38), control: CGPoint(x: 41, y: 41))
            ctx.stroke(eye, with: ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            var wl = Path(); wl.move(to: CGPoint(x: 22, y: 47)); wl.addLine(to: CGPoint(x: 10, y: 45)); wl.move(to: CGPoint(x: 22, y: 50)); wl.addLine(to: CGPoint(x: 11, y: 52))
            ctx.stroke(wl, with: paper, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            var wr = Path(); wr.move(to: CGPoint(x: 42, y: 47)); wr.addLine(to: CGPoint(x: 54, y: 45)); wr.move(to: CGPoint(x: 42, y: 50)); wr.addLine(to: CGPoint(x: 53, y: 52))
            ctx.stroke(wr, with: ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
    private static var head: Path {
        var p = Path()
        p.move(to: CGPoint(x: 14, y: 30))
        p.addLine(to: CGPoint(x: 12, y: 10)); p.addLine(to: CGPoint(x: 26, y: 20)); p.addLine(to: CGPoint(x: 38, y: 20))
        p.addLine(to: CGPoint(x: 52, y: 10)); p.addLine(to: CGPoint(x: 50, y: 30))
        p.addQuadCurve(to: CGPoint(x: 50, y: 50), control: CGPoint(x: 56, y: 40))
        p.addQuadCurve(to: CGPoint(x: 32, y: 60), control: CGPoint(x: 40, y: 60))
        p.addQuadCurve(to: CGPoint(x: 14, y: 50), control: CGPoint(x: 24, y: 60))
        p.addQuadCurve(to: CGPoint(x: 14, y: 30), control: CGPoint(x: 8, y: 40))
        p.closeSubpath()
        return p
    }
    private static var nose: Path {
        var p = Path(); p.move(to: CGPoint(x: 30, y: 46)); p.addLine(to: CGPoint(x: 34, y: 46)); p.addLine(to: CGPoint(x: 32, y: 49)); p.closeSubpath(); return p
    }
}

/// Kept for other views that still show a compact chip.
struct Chip: View {
    let text: String
    let color: Color
    var faded = false
    var dashed = false
    var body: some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.ink.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.ink.opacity(dashed ? 0.6 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .foregroundStyle(Color.ink.opacity(faded ? 0.4 : 0.8))
    }
}

extension Color {
    /// Ink and canvas follow the system appearance: black on white in light mode, white on black in dark mode.
    static var ink: Color { .primary }
    #if os(macOS)
    static var canvas: Color { Color(nsColor: .textBackgroundColor) }
    #else
    static var canvas: Color { Color(uiColor: .systemBackground) }
    #endif
}
