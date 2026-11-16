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
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if let z = zoomed {
                        nodeTree(z, depth: 0, kids: kids, trail: [], context: look.contextColor(rootIndex(z, roots: roots)), active: store.project(of: z).projectStatus == .active)
                    } else {
                        ForEach(Array(roots.enumerated()), id: \.element.id) { i, p in nodeTree(p, depth: 0, kids: kids, trail: [], context: look.contextColor(i), active: p.projectStatus == .active) }
                    }
                }
                .id(zoomID)
                .transition(.asymmetric(
                    insertion: .scale(scale: zoomingIn ? 0.94 : 1.06, anchor: .top).combined(with: .opacity),
                    removal: .opacity))
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
        // Always present, fixed height: the outline's top edge does not move when zooming in or out.
        .safeAreaInset(edge: .top, spacing: 0) { breadcrumbBar(zoomed) }
        // New item: fixed at the bottom right, over the list. Hidden while typing (the keyboard is up).
        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            if focused == nil && editRequest == nil {
                newItemButton {
                    let n = zoomed.map { store.create(parentID: $0.id, position: (kids[$0.id] ?? []).count) } ?? store.create()
                    store.save(); beginEdit(n.id)
                    // The new item goes at the end of the list: bring it into view.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(n.id, anchor: .center) }
                    }
                }
            }
        }
        // Zoomed in: a quick swipe right anywhere on the page goes back to the whole outline.
        #if os(iOS)
        .gesture(HorizontalPanGesture(onChanged: { _ in }, onEnded: { t, vx in
            if zoomID != nil && drag.id == nil && OutlineView.isBackSwipe(dx: t.width, dy: t.height, vx: vx) { zoom(to: nil) }
        }))
        #else
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { v in
            if zoomID != nil && drag.id == nil && OutlineView.isBackSwipe(v) { zoom(to: nil) }
        })
        #endif
        .background(Color.canvas)
        .navigationTitle("")
        #if os(iOS)
        // The breadcrumb bar is the header (logo, path, filter): the system navigation bar is not shown.
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            // Only while typing: Done (Escape on the Mac; above the keyboard on iPhone/iPad).
            if focused != nil || editRequest != nil {
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { endEdit() }.fontWeight(.semibold).keyboardShortcut(.escape, modifiers: [])
                }
                #else
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { endEdit() }.fontWeight(.semibold)
                }
                #endif
            }
        }
        // Another screen (Inbox, Calendar) asked to show an item: make it visible and scroll to it.
        .onChange(of: sel.revealID) { _, id in reveal(id, proxy) }
        }
    }

    private func reveal(_ id: UUID?, _ proxy: ScrollViewProxy) {
        guard let id, let n = store.node(id) else { return }
        sel.revealID = nil
        if let z = zoomID, !isInSubtree(id, of: z) { withAnimation(.snappy(duration: 0.32)) { zoomID = nil } }
        if !matches(n) { filter = .all; modeFilter = nil }
        var p = n.parentID
        while let pid = p, let x = store.node(pid) { if x.collapsed { store.update(x) { $0.collapsed = false } }; p = x.parentID }
        store.save()
        sel.nodeID = id; sel.infoID = id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
        }
    }

    private var filtering: Bool { filter != .all || modeFilter != nil }

    /// Filters, in a menu in the navigation bar. The icon fills in while a filter is on.
    private static let headerHeight: CGFloat = 28
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
            Divider()
            Toggle("Show square legend", isOn: Binding(get: { showLegend }, set: { v in withAnimation(.snappy(duration: 0.2)) { showLegend = v } }))
        } label: {
            // The header's right end: a block with a rounded right edge. Peach while a filter is on.
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .heavy)).foregroundStyle(.black)
                .padding(.leading, 10).padding(.trailing, 13).frame(height: Self.headerHeight)
                .background { UnevenRoundedRectangle(bottomTrailingRadius: Self.headerHeight / 2, topTrailingRadius: Self.headerHeight / 2).fill(filtering ? PanelPalette.peach : PanelPalette.orange) }
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(filtering ? "Filters (on)" : "Filters")
        .accessibilityLabel(filtering ? "Filters, on" : "Filters")
    }

    /// A quick, mostly horizontal swipe to the right: the "go back" gesture. Distinct from the slower row pull that indents.
    nonisolated static func isBackSwipe(_ v: DragGesture.Value) -> Bool {
        let dx = v.translation.width, dy = v.translation.height
        return dx > 60 && abs(dy) < max(50, dx * 0.5) && v.predictedEndTranslation.width - dx > 80
    }
    /// Same test from a translation and horizontal velocity (points/s), for the UIKit pan on iPhone/iPad.
    nonisolated static func isBackSwipe(dx: CGFloat, dy: CGFloat, vx: CGFloat) -> Bool {
        dx > 60 && abs(dy) < max(50, dx * 0.5) && vx > 300
    }

    /// Zoom into an item (nil = whole outline), animated.
    private func zoom(to id: UUID?) {
        endEdit()
        zoomingIn = id.map { target in zoomID.map { isInSubtree(target, of: $0) && target != $0 } ?? true } ?? false
        withAnimation(.snappy(duration: 0.32)) { zoomID = id; sel.nodeID = nil; sel.infoID = nil }
    }
    private func rootIndex(_ n: Node, roots: [Node]) -> Int {
        var r = n; while let pid = r.parentID, let p = store.node(pid) { r = p }
        return roots.firstIndex { $0.id == r.id } ?? 0
    }
    /// "+ NEW ITEM" in the panel style: two small color blocks leading into a labeled block with a rounded right end.
    private func newItemButton(_ action: @escaping () -> Void) -> some View {
        let h: CGFloat = 34
        return Button(action: action) {
            HStack(spacing: 3) {
                Rectangle().fill(PanelPalette.periwinkle).frame(width: 10, height: h).panelBlink(21)
                Rectangle().fill(PanelPalette.lavender).frame(width: 18, height: h).panelBlink(22)
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .heavy))
                    Text("NEW ITEM").font(PanelPalette.label(.subheadline))
                }
                .foregroundStyle(.black)
                .padding(.leading, 10).padding(.trailing, 16).frame(height: h)
                .background { UnevenRoundedRectangle(bottomTrailingRadius: h / 2, topTrailingRadius: h / 2).fill(PanelPalette.orange).panelBlink(23) }
            }
            .padding(4)
            .background(PanelPalette.field, in: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: h / 2 + 4, topTrailingRadius: h / 2 + 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 14).padding(.bottom, 10)
        .help("New item at the end of the list")
        .accessibilityLabel("New item")
    }

    /// The header: logo (tap = all items), the path down to the zoomed item as flat color blocks (tap one to go
    /// there), and the filter menu at the right end. Always shown, at a fixed height.
    private func breadcrumbBar(_ z: Node?) -> some View {
        var path: [Node] = []
        var p = z
        while let x = p { path.insert(x, at: 0); p = x.parentID.flatMap { store.node($0) } }
        let shown = Array(path.suffix(3))            // deepest three levels; earlier ones fold into "…"
        let h = Self.headerHeight
        return HStack(spacing: 3) {
            // Branding: the logo. It is also "all items": tap it to leave a zoom.
            Button { zoom(to: nil) } label: {
                CatLogo().frame(width: h + 4, height: h + 4).padding(.trailing, 5).contentShape(Rectangle())
            }
            .keyboardShortcut("[", modifiers: .command)
            .allowsHitTesting(z != nil)
            .accessibilityLabel(z == nil ? "Schrodinger" : "Schrodinger. All items")
            .accessibilityAddTraits(.isHeader)
            if path.count > shown.count {
                Text("\u{2026}").font(PanelPalette.label(.caption)).foregroundStyle(.black)
                    .padding(.horizontal, 8).frame(height: h).background { PanelPalette.rose.panelBlink(12) }
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, a in
                let current = a.id == z?.id
                Button { zoom(to: a.id) } label: {
                    Text((a.title.isEmpty ? "Untitled" : a.title).uppercased())
                        .font(PanelPalette.label(.caption)).foregroundStyle(.black)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 8).frame(maxWidth: current ? 180 : 110).frame(height: h)
                        .fixedSize(horizontal: !current, vertical: false)
                        // Only the block's color pulses; its label stays steady and readable.
                        .background { (current ? PanelPalette.peach : [PanelPalette.lavender, PanelPalette.periwinkle, PanelPalette.rose][i % 3]).panelBlink(13 + i) }
                }
                .allowsHitTesting(!current)
                .layoutPriority(current ? 1 : 0)
            }
            // Filler bar and end cap: the row always spans the full width.
            Rectangle().fill(z == nil ? PanelPalette.lavender : PanelPalette.periwinkle).frame(minWidth: 8).frame(height: h).panelBlink(17)
            filterMenu
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.canvas)
        .animation(.snappy(duration: 0.25), value: zoomID)
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

    /// Items under `n` (or `n` itself) the AI can work on right now. Empty = nothing to run, no play button.
    private func runnable(_ n: Node, kids: [UUID?: [Node]]) -> [UUID] {
        let c = kids[n.id] ?? []
        if c.isEmpty { return !n.isProject && ProjectAgent.aiTurn(n) && store.depsSatisfied(n) ? [n.id] : [] }
        return c.flatMap { runnable($0, kids: kids) }
    }

    /// `active`: the item's project is active (paused and archived projects don't run).
    private func nodeTree(_ n: Node, depth: Int, kids: [UUID?: [Node]], trail: [Color], context: Color, active: Bool) -> AnyView {
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
                    swipeBack: zoomID != nil,
                    runnable: active ? runnable(n, kids: kids) : [])
                .id(n.id)   // scroll target for reveal()
            if n.isProject { ProjectLine(node: n, progress: store.progress(of: n.id)) }
            if !n.collapsed || n.id == zoomID {
                ForEach(children) { c in nodeTree(c, depth: depth + 1, kids: kids, trail: trail + [own], context: context, active: active) }
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
        // Reference point: the item's own line, not the middle of the row (an open action strip makes the row taller).
        let y = own.minY + min(own.height, 40) / 2 + dy
        let rows = visibleOrder(excluding: n.id)
        // Insertion point: before the first row whose middle is below the finger.
        var idx = rows.firstIndex { $0.frame.minY + min($0.frame.height, 40) / 2 > y } ?? rows.count
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
            // Target index among the on-screen siblings (stored positions can have gaps or duplicates).
            try? s.move(n, to: n.parentID, position: to); s.save(); keep()
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
/// Every item's square has this same shape. Color = the item's mode (or, with no mode, its project's context color).
///   who holds it: mine or unassigned = blank · AI = sparkles glyph · both = a single sparkle
///   state:        todo/in progress/done = solid · review = hollow · blocked = dashed outline
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

    /// The square is filled (glyph is drawn in the background color) rather than outlined (glyph in the square's color).
    private var solid: Bool { isProject || (state != .review && state != .blocked) }

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
                // AI involvement is a glyph inside the square; the square itself never changes shape.
                if let glyph = assignee.squareGlyph {
                    Image(systemName: glyph)
                        .font(.system(size: assignee == .ai ? 9.5 : 8, weight: .heavy))
                        .foregroundStyle(solid ? Color.canvas : color)
                        .offset(x: -0.5)   // optical center: the right side is rounded
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
    /// Glyph drawn inside the item's square: sparkles when the AI holds it, one sparkle when it is shared, nothing
    /// when it is mine or unassigned.
    var squareGlyph: String? {
        switch self { case .ai: "sparkles"; case .shared: "sparkle"; case .human, .unassigned: nil }
    }
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
            row(StatusBar(state: .todo, assignee: .human, isProject: false), "me, or unassigned")
            row(StatusBar(state: .todo, assignee: .ai, isProject: false), "ai")
            row(StatusBar(state: .todo, assignee: .shared, isProject: false), "both")
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
    /// Items the AI can work on now, in this item or under it. Non-empty = show the play button.
    var runnable: [UUID] = []
    @Environment(HarnessEngine.self) private var harness
    @State private var runFailure: String? = nil
    @State private var title: String = ""
    @State private var pull: CGFloat = 0
    /// A long press lifted this item during the current touch; the tap that its release completes must not zoom.
    @State private var holdFired = false
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
        withAnimation(.easeOut(duration: 0.15)) {
            if sel.nodeID == node.id { sel.nodeID = nil; if infoOpen { sel.infoID = nil } } else { sel.nodeID = node.id }
        }
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
    private var infoOpen: Bool { sel.infoID == node.id }

    /// This row's work is part of the run in progress.
    private var runningHere: Bool {
        guard harness.running else { return false }
        guard let scope = harness.runningScope else { return true }
        return runnable.contains { scope.contains($0) }
    }
    /// Play: have the AI do its work on this item (for a parent, on the ready items under it). Shown only when
    /// there is something to run.
    @ViewBuilder private var runButton: some View {
        if runningHere {
            ProgressView().controlSize(.small).frame(width: 28, height: 28).accessibilityLabel("Running")
        } else {
            Button { run() } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(harness.running)
            .opacity(harness.running ? 0.3 : 1)
            .help(runnable.count == 1 ? "Run: have the AI work on this" : "Run: have the AI work on \(runnable.count) items here")
            .accessibilityLabel(runnable.count == 1 ? "Run" : "Run \(runnable.count) items")
        }
    }
    private func run() {
        commit()
        let ids = Set(runnable), project = store.project(of: node).id
        Task { @MainActor in
            let out = await harness.runOnce(projectID: project, only: ids)
            let bad = out.flatMap { $0.components(separatedBy: "\n") }.filter { $0.hasPrefix("failed:") || $0.contains(": error") }
            if !bad.isEmpty { runFailure = bad.joined(separator: "\n") }
        }
    }
    /// Tap on the squares: show the action strip with the item's drafts, context and details under it; again hides both.
    private func toggleInfo() {
        withAnimation(.snappy(duration: 0.22)) {
            if infoOpen { sel.infoID = nil; if sel.nodeID == node.id { sel.nodeID = nil } } else { sel.nodeID = node.id; sel.infoID = node.id }
        }
    }
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
                // Tap the squares: open/close the item's sheet (action strip + drafts, context, details).
                .onTapGesture { squareTapped() }
                #if os(iOS)
                .gesture(holdDrag)
                #else
                .simultaneousGesture(handleGesture)
                #endif
                .alignmentGuide(.rowLine) { _ in 4 + StatusBar.h / 2 }   // middle of the bars
                .help(summary + " · tap for the item's details and actions · hold and drag to move")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary)
                .accessibilityHint(infoOpen ? "Hides details" : "Shows details and actions")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { commit(); toggleInfo() }
                .accessibilityAction(named: "Zoom in") { commit(); onZoom() }

            VStack(alignment: .leading, spacing: 2) {
            // Tap shows/hides the item's children; hold zooms in (again on the zoomed item zooms out); hold and move drags;
            // double-tap edits the text.
            if !editing {
                Text(title.isEmpty ? "New item" : title)
                    .font(titleFont)
                    .strikethrough(done)
                    .foregroundStyle(title.isEmpty ? Color.ink.opacity(0.3) : done ? Color.ink.opacity(0.4) : Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEdit() }
                    .onTapGesture { tapped() }
                    // Same as the bars: hold and release shows/hides the action strip; hold and move drags the item.
                    // iPhone/iPad: a UIKit long press (see TouchGestures.swift); SwiftUI drag gestures here stop the list from
                    // scrolling on iOS 18+. A swipe fails the hold and scrolls; once lifted, scrolling is disabled.
                    #if os(iOS)
                    .gesture(holdDrag)
                    #else
                    .simultaneousGesture(handleGesture)
                    #endif
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
            if !runnable.isEmpty { runButton.alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] } }
            if hasChildren && node.collapsed {
                // Children are hidden: tap the … to show them.
                Button { commit(); withAnimation(.snappy(duration: 0.22)) { toggleChildren() } } label: {
                    Text("\u{2026}").font(.title3.weight(.bold)).foregroundStyle(Color.ink.opacity(0.6))
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
                .help("Show children")
                .accessibilityLabel("Show children")
            }
        }
        .padding(.vertical, 6)
        .onAppear { title = node.title; note = node.notes; showNote = !node.notes.isEmpty }
        .onChange(of: node.title) { _, v in if v != title { title = v } }
        .onChange(of: node.notes) { _, v in if v != note { note = v; if !v.isEmpty { showNote = true } } }
        .onChange(of: handleActive) { _, active in if !active { finishDrag() } }
        .sensoryFeedback(.impact(weight: .medium), trigger: lifting) { _, now in now }
        .alert("Run failed", isPresented: Binding(get: { runFailure != nil }, set: { if !$0 { runFailure = nil } })) { Button("OK") {} } message: { Text(runFailure ?? "") }
        .onChange(of: focused.wrappedValue) { old, new in
            if new == node.id { sel.nodeID = node.id; if editRequest == node.id { editRequest = nil } }
            if old == node.id && new != node.id { commit() }
        }
        if infoOpen {
            // The item sheet: the action strip and one text field on a plain black panel.
            ItemPanel {
                actionStrip
                ItemSheetBody(node: node)
            }
            .padding(.leading, CGFloat(depth) * StatusBar.step + 4).padding(.bottom, 10)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if sel.nodeID == node.id || editing {
            actionStrip.padding(.leading, CGFloat(depth) * StatusBar.step + 4).padding(.bottom, 8).transition(.opacity)
        }
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
        #if os(iOS)
        .gesture(HorizontalPanGesture(onChanged: { t in pullChanged(t) }, onEnded: { t, vx in
            pullEnded(isBack: swipeBack && OutlineView.isBackSwipe(dx: t.width, dy: t.height, vx: vx))
        }))
        #else
        .simultaneousGesture(pullGesture)
        #endif
        #if os(macOS)
        // Right-click menu on the Mac. On iPhone/iPad a long-press context menu would take over the touch and cancel
        // the hold-and-drag on the bars (and the long press that opens the action strip), so the strip is used there.
        .contextMenu { menu }
        #endif
    }

    /// Pull to move: drag the row left to outdent (←), right to indent (→). The text moves the way it will land.
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { v in pullChanged(v.translation) }
            .onEnded { v in pullEnded(isBack: swipeBack && OutlineView.isBackSwipe(v)) }
    }
    private func pullChanged(_ t: CGSize) {
        guard drag.id == nil, abs(t.width) > abs(t.height) * 1.2 else { return }
        var x = t.width
        if node.isProject && x < 0 { x = 0 }
        pull = max(-pullThreshold * 1.6, min(pullThreshold * 1.6, x * 0.6))
    }
    /// `isBack`: the swipe was the page's "go back" gesture, so it must not also indent.
    private func pullEnded(isBack: Bool) {
        let p = pull
        withAnimation(.snappy(duration: 0.22)) { pull = 0 }
        if isBack { return }
        if p < -pullThreshold { commit(); onKey(.shiftTab) }
        else if p > pullThreshold { commit(); onKey(.tab) }
    }

    #if os(iOS)
    /// Hold 0.25 s to lift (release without moving = zoom in), then move to drag.
    private var holdDrag: HoldDragGesture {
        HoldDragGesture(onBegan: { lift() }, onChanged: { t in
            guard drag.id == node.id else { return }
            drag.dx = t.width; drag.dy = t.height
            onDragChanged(drag.dx, drag.dy)
        }, onEnded: { finishDrag() })
    }
    #endif
    private func lift() {
        guard drag.id == nil else { return }
        holdFired = true
        pull = 0; commit(); drag.origin = drag.frames[node.id]; drag.id = node.id; drag.dx = 0; drag.dy = 0
    }
    /// Single tap on the text shows or hides the item's children; on an item with no text it starts editing. Releasing a long press also completes a tap; that
    /// tap is ignored, so a long press only zooms (or drops a dragged item).
    private func tapped() {
        if holdFired { holdFired = false; return }
        // An item with no text yet ("New item"): a tap starts typing.
        if title.trimmingCharacters(in: .whitespaces).isEmpty { startEdit(); return }
        commit()
        if hasChildren { withAnimation(.snappy(duration: 0.22)) { toggleChildren() } }
    }
    /// Tap on the squares: the item's sheet. Same hold guard as `tapped()`.
    private func squareTapped() {
        if holdFired { holdFired = false; return }
        commit(); toggleInfo()
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
                lift()
                guard let d else { return }
                drag.dx = d.translation.width; drag.dy = d.translation.height
                onDragChanged(drag.dx, drag.dy)
            }
    }
    /// Ends a lift whether the gesture finished or was cancelled (GestureState resets in both cases; onEnded does not
    /// run on cancel, which used to leave the row stuck lifted).
    private func finishDrag() {
        guard drag.id == node.id else { return }
        // Held and released without moving: a long press, which zooms into the item instead of moving it.
        let still = abs(drag.dx) < 6 && abs(drag.dy) < 6
        drag.dx = 0; drag.dy = 0
        // The release's tap (if any) arrives about now; stop ignoring taps shortly after.
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); holdFired = false }
        if still { drag.target = nil; onDrop(); onZoom(); return }
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

    /// Right edge: due date and "your turn" for a single item. Parents show nothing here. The bars carry everything else.
    @ViewBuilder private var marker: some View {
        if !hasChildren && !node.isProject {
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
                if node.state == .review {
                    // An AI draft is waiting: approve it, or send it back to be redone.
                    Pill(systemImage: "checkmark.seal", on: true) { try? store.approve(node); store.save() }.help("Approve the draft").accessibilityLabel("Approve draft")
                    Pill(systemImage: "arrow.counterclockwise") { try? store.reject(node, note: ""); store.save() }.help("Have the AI redo the draft").accessibilityLabel("Redo draft")
                }
                PillMenu(systemImage: "ellipsis", title: nil) {
                    if hasChildren { Button { toggleChildren() } label: { Label(node.collapsed ? "Show children" : "Hide children", systemImage: node.collapsed ? "chevron.down" : "chevron.up") } }
                    if node.isYourTurn { Button { try? store.sendBackToAI(node, note: ""); store.save() } label: { Label("Send back to AI", systemImage: "sparkles") } }
                    if !node.isProject && !infoOpen { Button { openNote() } label: { Label(showNote ? "Edit context" : "Add context", systemImage: "text.alignleft") } }
                    Button { toggleInfo() } label: { Label(infoOpen ? "Close sheet" : "Open sheet", systemImage: "rectangle.and.text.magnifyingglass") }
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
        Button(infoOpen ? "Hide info" : "Info") { toggleInfo() }
        Button("Delete", role: .destructive) { deleteItem() }
    }

    private func openNote() { showNote = true; DispatchQueue.main.async { noteFocused = true } }
    /// Clear focus and selection first so nothing reads the node after it is gone, then delete.
    private func deleteItem() {
        endEdit(); noteFocused = false
        if sel.nodeID == node.id { sel.nodeID = nil }
        if sel.infoID == node.id { sel.infoID = nil }
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
    @Environment(\.panelStyle) private var panelStyle
    var body: some View {
        HStack(spacing: 4) {
            if let i = systemImage { Image(systemName: i).font(.system(size: panelStyle ? 13 : 11, weight: panelStyle ? .bold : .semibold)) }
            if let t = title { Text(t).font(.caption.weight(.medium)).lineLimit(1) }
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.5) }
        }
        .padding(.horizontal, panelStyle ? 14 : (title == nil ? 8 : 10)).padding(.vertical, 6)
        .frame(minWidth: panelStyle ? 46 : 30, minHeight: panelStyle ? 32 : 28)
        .background(fill, in: Capsule())
        .foregroundStyle(panelStyle ? Color.black : (on ? Color.canvas : Color.ink.opacity(0.8)))
        .contentShape(Capsule())
    }
    /// In the item sheet: flat colored capsules (peach when on); elsewhere: ink on canvas.
    private var fill: Color {
        if panelStyle { return on ? PanelPalette.peach : PanelPalette.color(for: (systemImage ?? "") + (title ?? "")) }
        return on ? Color.ink : Color.ink.opacity(0.06)
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
