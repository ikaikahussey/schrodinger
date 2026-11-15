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

    enum Filter: String, CaseIterable, Identifiable { case all, mine, ai, review, blocked, week; var id: String { rawValue }
        var label: String { switch self { case .all: "All"; case .mine: "Mine"; case .ai: "AI"; case .review: "Review"; case .blocked: "Blocked"; case .week: "This week" } } }

    private var store: Store { Store(ctx) }
    private var childrenMap: [UUID?: [Node]] { Dictionary(grouping: all, by: { $0.parentID }).mapValues { $0.sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) } } }

    var body: some View {
        let kids = childrenMap
        let roots = kids[nil] ?? []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(roots) { p in nodeTree(p, depth: 0, kids: kids) }
                Button { let n = store.create(); store.save(); beginEdit(n.id) } label: {
                    HStack(spacing: 10) { Image(systemName: "plus").font(.caption.weight(.semibold)); Text("New item").font(.callout) }
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary).padding(.vertical, 10).padding(.leading, 6)
                if showLegend { BarLegend().padding(.top, 24) }
            }
            .padding(.horizontal, 16).padding(.top, 8)
            .coordinateSpace(name: "outline")
            .onPreferenceChange(RowFrameKey.self) { v in Task { @MainActor in drag.frames = v } }
            .overlay(alignment: .topLeading) {
                if let t = drag.target, drag.id != nil {
                    Rectangle().fill(Color.ink).frame(height: 2)
                        .padding(.leading, 16 + CGFloat(t.depth) * StatusBar.step).padding(.trailing, 16)
                        .offset(y: t.y - 1)
                        .allowsHitTesting(false)
                }
            }
        }
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
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text($0.label).tag($0) } }
                    Picker("Mode", selection: $modeFilter) { Text("Any mode").tag(Mode?.none); ForEach(Mode.allCases) { Text($0.label).tag(Mode?.some($0)) } }
                    Divider()
                    Toggle("Show bar legend", isOn: $showLegend)
                } label: { Image(systemName: filter == .all && modeFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }
            }
        }
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
        beginEdit(n.id)
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

    private func nodeTree(_ n: Node, depth: Int, kids: [UUID?: [Node]]) -> AnyView {
        let children = kids[n.id] ?? []
        let hidden = (filter != .all || modeFilter != nil) && depth > 0 && !subtreeMatches(n, kids: kids)
        if hidden { return AnyView(EmptyView()) }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            NodeRow(node: n, depth: depth, hasChildren: !children.isEmpty, leafCount: leafCount(n, kids: kids), sel: sel, focused: $focused, editRequest: $editRequest, drag: drag,
                    onKey: { key in handleKey(key, n, kids: kids) },
                    onDragChanged: { dx, dy in updateDropTarget(n, dx: dx, dy: dy) },
                    onDrop: { performDrop(n) })
            if n.isProject { ProjectLine(node: n, progress: store.progress(of: n.id)) }
            if !n.collapsed {
                ForEach(children) { c in nodeTree(c, depth: depth + 1, kids: kids) }
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
        guard let own = drag.frames[n.id] else { return }
        let y = own.midY + dy
        let rows = visibleOrder(excluding: n.id)
        // Insertion point: before the first row whose middle is below the finger.
        let idx = rows.firstIndex { $0.frame.midY > y } ?? rows.count
        let above = idx > 0 ? rows[idx - 1] : nil
        let below = idx < rows.count ? rows[idx] : nil
        let lineY = above.map { $0.frame.maxY } ?? below.map { $0.frame.minY } ?? own.minY
        let maxD = (above?.depth ?? -1) + 1
        let minD = below?.depth ?? 0
        let want = (above?.depth ?? 0) + Int((dx / 44).rounded())
        let depth = max(min(minD, maxD), min(maxD, want))
        drag.target = OutlineDrag.Target(y: lineY, depth: depth, aboveID: above?.node.id)
    }

    private func performDrop(_ n: Node) {
        defer { drag.target = nil; drag.id = nil }
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
            if !(kids[n.id] ?? []).isEmpty && !n.collapsed { created = s.create(parentID: n.id, position: 0) }
            else { created = s.create(parentID: n.parentID, assignee: n.isProject ? nil : n.assignee, position: n.position + 1) }
            s.save(); beginEdit(created.id)
        case .tab:
            let siblings = kids[n.parentID] ?? []
            guard let idx = siblings.firstIndex(where: { $0.id == n.id }), idx > 0 else { return }
            try? s.move(n, to: siblings[idx - 1].id, position: 999); s.save(); keep()
        case .shiftTab:
            guard let pid = n.parentID, let parent = s.node(pid) else { return }
            try? s.move(n, to: parent.parentID, position: parent.position + 1); s.save(); keep()
        case .backspaceEmpty:
            guard (kids[n.id] ?? []).isEmpty else { return }
            let siblings = kids[n.parentID] ?? []
            let idx = siblings.firstIndex(where: { $0.id == n.id }) ?? 0
            s.delete(n); s.save()
            if idx > 0 { beginEdit(siblings[idx - 1].id) }
        case .altUp: try? s.move(n, to: n.parentID, position: max(0, n.position - 1)); s.save(); keep()
        case .altDown: try? s.move(n, to: n.parentID, position: n.position + 1); s.save(); keep()
        }
    }
}

@Observable @MainActor final class OutlineDrag {
    struct Target: Equatable { var y: CGFloat; var depth: Int; var aboveID: UUID? }
    var id: UUID? = nil
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var frames: [UUID: CGRect] = [:]
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
        .padding(.leading, 24).padding(.trailing, 4).padding(.bottom, 4)
        .opacity(progress.total == 0 ? 0 : 1)
    }
}

// MARK: - Bars

/// The item's own bar. Encodes state (fill), assignee (shape) and nothing else.
///   state:    todo/in progress = solid · review = hollow · blocked = dashed · done = solid (the text is struck through)
///   assignee: human = one bar · ai = bar with a gap · shared = two thin bars side by side · unassigned = half-height bar
/// Every bar is full ink (black in light mode, white in dark mode), never gray, and fits the same w × h footprint.
struct StatusBar: View {
    let state: TaskState
    let assignee: Assignee
    let isProject: Bool
    static let h: CGFloat = 16
    static let w: CGFloat = 6
    /// Horizontal distance from one depth bar to the next (bar width + gap).
    static let step: CGFloat = w + 3

    var body: some View {
        let h = Self.h
        Group {
            if isProject {
                RoundedRectangle(cornerRadius: 1).fill(Color.ink).frame(width: Self.w, height: h)
            } else {
                switch assignee {
                case .ai:
                    VStack(spacing: 3) { styled.frame(height: (h - 3) * 0.4); styled.frame(height: (h - 3) * 0.6) }.frame(width: Self.w, height: h)
                case .shared:
                    HStack(spacing: 2) { styled.frame(width: (Self.w - 2) / 2, height: h); styled.frame(width: (Self.w - 2) / 2, height: h) }
                case .human:
                    styled.frame(width: Self.w, height: h)
                case .unassigned:
                    styled.frame(width: Self.w, height: h / 2).frame(width: Self.w, height: h, alignment: .top)
                }
            }
        }
    }

    @ViewBuilder private var styled: some View {
        let shape = RoundedRectangle(cornerRadius: 1)
        switch state {
        case .review:  shape.strokeBorder(Color.ink, lineWidth: 1.5)
        case .blocked: shape.strokeBorder(Color.ink, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
        default:       shape.fill(Color.ink)
        }
    }
}

/// One bar per depth level: ancestors solid, the item's own bar styled by StatusBar, mode emoji beneath. Tap = menu.
struct DepthBars: View {
    let node: Node
    let depth: Int
    let hasChildren: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<max(depth, 0), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1).fill(Color.ink).frame(width: StatusBar.w, height: StatusBar.h)
                }
                StatusBar(state: node.state, assignee: node.assignee, isProject: node.isProject)
            }
            if let m = node.mode, !node.isProject {
                Text(m.emoji).font(.system(size: 10)).fixedSize()
                    .padding(.leading, CGFloat(depth) * StatusBar.step)
            }
        }
        .frame(minWidth: CGFloat(depth) * StatusBar.step + 14, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension VerticalAlignment {
    /// Row alignment: middle of the bars = middle of the first line of text.
    private enum RowLine: AlignmentID { static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] } }
    static var rowLine: VerticalAlignment { VerticalAlignment(RowLine.self) }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Bars").font(.caption.weight(.semibold)).foregroundStyle(Color.ink.opacity(0.6))
            row(StatusBar(state: .todo, assignee: .human, isProject: false), "me")
            row(StatusBar(state: .todo, assignee: .ai, isProject: false), "ai")
            row(StatusBar(state: .todo, assignee: .shared, isProject: false), "both")
            row(StatusBar(state: .todo, assignee: .unassigned, isProject: false), "unassigned")
            row(StatusBar(state: .review, assignee: .human, isProject: false), "review")
            row(StatusBar(state: .blocked, assignee: .human, isProject: false), "blocked")
            row(StatusBar(state: .done, assignee: .human, isProject: false), "done")
            Text("Emoji under the bar is the mode: " + Mode.allCases.map(\.label).joined(separator: " · "))
                .font(.caption2).foregroundStyle(Color.ink.opacity(0.5))
        }
        .padding(.leading, 6)
    }
    private func row(_ bar: StatusBar, _ label: String) -> some View {
        HStack(spacing: 10) { bar.frame(width: 10, alignment: .leading); Text(label).font(.caption2).foregroundStyle(Color.ink.opacity(0.6)) }
    }
}

// MARK: - Row

struct NodeRow: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var node: Node
    let depth: Int
    let hasChildren: Bool
    let leafCount: (done: Int, total: Int)
    var sel: Selection
    var focused: FocusState<UUID?>.Binding
    @Binding var editRequest: UUID?
    let drag: OutlineDrag
    let onKey: (OutlineView.Key) -> Void
    let onDragChanged: (CGFloat, CGFloat) -> Void
    let onDrop: () -> Void
    @State private var title: String = ""
    @State private var pull: CGFloat = 0
    private var lifting: Bool { drag.id == node.id }
    @State private var note: String = ""
    @State private var showNote = false
    @FocusState private var noteFocused: Bool
    private let pullThreshold: CGFloat = 56

    private var store: Store { Store(ctx) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .rowLine, spacing: 10) {
            Button { commit(); toggleSelect() } label: {
                DepthBars(node: node, depth: depth, hasChildren: hasChildren)
                    .padding(.vertical, 4).padding(.trailing, 6)   // wider grab area
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .alignmentGuide(.rowLine) { _ in 4 + StatusBar.h / 2 }   // middle of the bars
            .help(summary + " · tap for actions, tap again to hide · drag to move")
            .accessibilityLabel(summary)
            .simultaneousGesture(handleGesture)

            VStack(alignment: .leading, spacing: 2) {
            // Tap selects (shows the action strip), tap again deselects (hides it); long press (or double-tap) edits the text.
            if !editing {
                Text(title.isEmpty ? "New item" : title)
                    .font(node.isProject ? .title3.weight(.semibold) : .body)
                    .strikethrough(done)
                    .foregroundStyle(title.isEmpty ? Color.ink.opacity(0.3) : done ? Color.ink.opacity(0.4) : Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEdit() }
                    .onTapGesture { commit(); toggleSelect() }
                    .onLongPressGesture(minimumDuration: 0.35) { startEdit() }
            } else {
            TextField("", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(node.isProject ? .title3.weight(.semibold) : .body)
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
                    .font(.callout)
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
        .padding(.leading, 6)
        .onAppear { title = node.title; note = node.notes; showNote = !node.notes.isEmpty }
        .onChange(of: node.title) { _, v in if v != title { title = v } }
        .onChange(of: node.notes) { _, v in if v != note { note = v; if !v.isEmpty { showNote = true } } }
        .onChange(of: focused.wrappedValue) { old, new in
            if new == node.id { sel.nodeID = node.id; if editRequest == node.id { editRequest = nil } }
            if old == node.id && new != node.id { commit() }
        }
        if sel.nodeID == node.id || editing { actionStrip.padding(.leading, 6 + CGFloat(depth) * StatusBar.step).padding(.bottom, 8).transition(.opacity) }
        }
        .background(sel.nodeID == node.id ? Color.ink.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .background(GeometryReader { g in Color.clear.preference(key: RowFrameKey.self, value: [node.id: g.frame(in: .named("outline"))]) })
        .offset(x: pull + (lifting ? drag.dx * 0.3 : 0), y: lifting ? drag.dy : 0)
        .background(Color.canvas.opacity(lifting ? 1 : 0), in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(lifting ? 0.18 : 0), radius: lifting ? 8 : 0, y: 2)
        .opacity(lifting ? 0.92 : 1)
        .zIndex(lifting ? 1 : 0)
        // Arrows sit at fixed edges: ← outdent on the left, → indent on the right. Pull toward an arrow to use it.
        .overlay(alignment: .leading) { pullArrow("arrow.left", active: pull < -pullThreshold, show: pull < -8).offset(x: -4) }
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
            .onEnded { _ in
                let p = pull
                withAnimation(.snappy(duration: 0.22)) { pull = 0 }
                if p < -pullThreshold { commit(); onKey(.shiftTab) }
                else if p > pullThreshold { commit(); onKey(.tab) }
            }
    }

    /// The bars are the handle. A short sideways pull indents/outdents; anything else lifts the item and lets you drop it
    /// anywhere in the outline (horizontal position while dragging picks the depth at the drop point).
    private var handleGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { v in
                let dx = v.translation.width, dy = v.translation.height
                if drag.id == nil && abs(dy) < 10 && abs(dx) > abs(dy) * 1.3 {
                    var x = dx; if node.isProject && x < 0 { x = 0 }
                    pull = max(-pullThreshold * 1.6, min(pullThreshold * 1.6, x * 0.6))
                } else {
                    if drag.id == nil { pull = 0; drag.id = node.id; commit() }
                    drag.dx = dx; drag.dy = dy
                    onDragChanged(dx, dy)
                }
            }
            .onEnded { _ in
                let p = pull
                withAnimation(.snappy(duration: 0.22)) { pull = 0 }
                if drag.id == node.id {
                    withAnimation(.snappy(duration: 0.22)) { drag.dx = 0; drag.dy = 0 }
                    onDrop()
                } else if p < -pullThreshold { commit(); onKey(.shiftTab) }
                else if p > pullThreshold { commit(); onKey(.tab) }
            }
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

    /// The item's actions, on screen (shown under the selected row). Related choices are grouped into menus:
    /// responsible, status, mode, move, and more (context, details, delete). Edit and add stay one tap.
    @ViewBuilder private var actionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if editing {
                    Pill(systemImage: "checkmark", title: "Done", on: true) { commit(); endEdit() }.help("Finish editing")
                } else {
                    Pill(systemImage: "pencil", title: "Edit") { startEdit() }.help("Edit text")
                }
                if !node.isProject {
                    PillMenu(systemImage: "person", title: node.assignee == .unassigned ? "—" : node.assignee.label) {
                        Picker("Responsible", selection: assigneeBinding) { ForEach(Assignee.allCases) { Text($0.label).tag($0) } }.pickerStyle(.inline)
                    }.help("Responsible")
                    PillMenu(systemImage: "circle.dotted", title: node.state == .in_progress ? "doing" : node.state.label) {
                        Picker("Status", selection: stateBinding) { ForEach(TaskState.allCases) { Text($0 == .in_progress ? "doing" : $0.label).tag($0) } }.pickerStyle(.inline)
                    }.help("Status")
                    PillMenu(systemImage: node.mode == nil ? "tag" : nil, title: node.mode?.label ?? "mode") {
                        Picker("Mode", selection: modeBinding) { Text("none").tag(Mode?.none); ForEach(Mode.allCases) { Text($0.label).tag(Mode?.some($0)) } }.pickerStyle(.inline)
                    }.help("Mode")
                }
                PillMenu(systemImage: "arrow.up.and.down.and.arrow.left.and.right", title: "Move") {
                    Button { onKey(.altUp) } label: { Label("Move up", systemImage: "arrow.up") }
                    Button { onKey(.altDown) } label: { Label("Move down", systemImage: "arrow.down") }
                    if !node.isProject {
                        Button { onKey(.tab) } label: { Label("Indent", systemImage: "arrow.right") }
                        Button { onKey(.shiftTab) } label: { Label("Outdent", systemImage: "arrow.left") }
                    }
                }.help("Move")
                Pill(systemImage: "plus") { onKey(.enter) }.help("Add item below")
                PillMenu(systemImage: "ellipsis", title: nil) {
                    if !node.isProject { Button { openNote() } label: { Label(showNote ? "Edit context" : "Add context", systemImage: "text.alignleft") } }
                    Button { sel.nodeID = node.id; sel.panel = .review } label: { Label("Details", systemImage: "info.circle") }
                    Divider()
                    Button(role: .destructive) { store.delete(node); store.save() } label: { Label("Delete", systemImage: "trash") }
                }.help("More")
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
        Button("Delete", role: .destructive) { store.delete(node); store.save() }
    }

    private func openNote() { showNote = true; DispatchQueue.main.async { noteFocused = true } }
    private func commitNote() {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if n != node.notes { store.update(node) { $0.notes = n }; store.save() }
        note = n
        if n.isEmpty { showNote = false }
    }

    private func commit() {
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
        Menu { content() } label: { PillLabel(systemImage: systemImage, title: title, chevron: title != nil) }
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
