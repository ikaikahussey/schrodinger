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
                Button { let n = store.create(); store.save(); focused = n.id } label: {
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
                        .padding(.leading, 16 + CGFloat(t.depth) * 7).padding(.trailing, 16)
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
            ToolbarItem(placement: .principal) { Text("Schrodinger").font(.headline) }
            ToolbarItem(placement: .primaryAction) {
                Button { ctx.undoManager?.undo(); store.save() } label: { Image(systemName: "arrow.uturn.backward") }.help("Undo")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button { ctx.undoManager?.redo(); store.save() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            }
            if focused != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { focused = nil }.fontWeight(.semibold).keyboardShortcut(.escape, modifiers: [])
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }.fontWeight(.semibold)
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
                    Picker("Mode", selection: $modeFilter) { Text("Any mode").tag(Mode?.none); ForEach(Mode.allCases) { Text($0.rawValue).tag(Mode?.some($0)) } }
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
        focused = n.id
    }

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
            NodeRow(node: n, depth: depth, hasChildren: !children.isEmpty, leafCount: leafCount(n, kids: kids), sel: sel, focused: $focused, drag: drag,
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
        switch key {
        case .enter:
            let created: Node
            if !(kids[n.id] ?? []).isEmpty && !n.collapsed { created = s.create(parentID: n.id, position: 0) }
            else { created = s.create(parentID: n.parentID, assignee: n.isProject ? nil : n.assignee, position: n.position + 1) }
            s.save(); focused = created.id
        case .tab:
            let siblings = kids[n.parentID] ?? []
            guard let idx = siblings.firstIndex(where: { $0.id == n.id }), idx > 0 else { return }
            try? s.move(n, to: siblings[idx - 1].id, position: 999); s.save(); focused = n.id
        case .shiftTab:
            guard let pid = n.parentID, let parent = s.node(pid) else { return }
            try? s.move(n, to: parent.parentID, position: parent.position + 1); s.save(); focused = n.id
        case .backspaceEmpty:
            guard (kids[n.id] ?? []).isEmpty else { return }
            let siblings = kids[n.parentID] ?? []
            let idx = siblings.firstIndex(where: { $0.id == n.id }) ?? 0
            s.delete(n); s.save()
            if idx > 0 { focused = siblings[idx - 1].id }
        case .altUp: try? s.move(n, to: n.parentID, position: max(0, n.position - 1)); s.save(); focused = n.id
        case .altDown: try? s.move(n, to: n.parentID, position: n.position + 1); s.save(); focused = n.id
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
///   state:    todo/in progress = solid · review = hollow · blocked = dashed · done = faint
///   assignee: human = one bar · ai = bar with a gap · shared = two half-height bars side by side · unassigned = thin
struct StatusBar: View {
    let state: TaskState
    let assignee: Assignee
    let isProject: Bool
    static let h: CGFloat = 16
    static let w: CGFloat = 4

    var body: some View {
        let h = Self.h
        Group {
            if isProject {
                RoundedRectangle(cornerRadius: 1).fill(Color.ink).frame(width: Self.w + 2, height: h)
            } else {
                switch assignee {
                case .ai:
                    VStack(spacing: 3) { styled.frame(height: (h - 3) * 0.4); styled.frame(height: (h - 3) * 0.6) }.frame(width: Self.w, height: h)
                case .shared:
                    HStack(spacing: 2) { styled.frame(width: 2, height: h); styled.frame(width: 2, height: h) }
                case .human:
                    styled.frame(width: Self.w, height: h)
                case .unassigned:
                    styled.frame(width: 1.5, height: h)
                }
            }
        }
        .opacity(state == .done ? 0.25 : 1)
    }

    @ViewBuilder private var styled: some View {
        let shape = RoundedRectangle(cornerRadius: 1)
        switch state {
        case .review:  shape.strokeBorder(Color.ink, lineWidth: 1)
        case .blocked: shape.strokeBorder(Color.ink, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        default:       shape.fill(Color.ink)
        }
    }
}

/// One bar per depth level: ancestors faint, the item's own bar styled by StatusBar, mode letter beneath. Tap = menu.
struct DepthBars: View {
    let node: Node
    let depth: Int
    let hasChildren: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<max(depth, 0), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1).fill(Color.ink.opacity(0.18)).frame(width: 3, height: StatusBar.h)
                }
                StatusBar(state: node.state, assignee: node.assignee, isProject: node.isProject)
                if hasChildren && node.collapsed {
                    Text("\u{2026}").font(.caption2).foregroundStyle(Color.ink.opacity(0.45)).offset(y: -4)
                }
            }
            if let m = node.mode, !node.isProject {
                Text(m.glyph).font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(Color.ink.opacity(0.55))
                    .padding(.leading, CGFloat(depth) * 6)
            }
        }
        .frame(minWidth: 10, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension Mode {
    /// One-letter glyph shown under the bars.
    var glyph: String {
        switch self {
        case .call: "c"; case .errand: "e"; case .email: "m"; case .write: "w"; case .research: "r"; case .meeting: "t"; case .admin: "a"; case .other: "o"
        }
    }
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
            Text("Letter under the bar is the mode: c call · e errand · m email · w write · r research · t meeting · a admin · o other")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 10) {
            Button { commit(); toggleSelect() } label: {
                DepthBars(node: node, depth: depth, hasChildren: hasChildren)
                    .padding(.vertical, 4).padding(.trailing, 6)   // wider grab area
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -1)
            .help(summary + " · tap for actions, tap again to hide · drag to move")
            .accessibilityLabel(summary)
            .simultaneousGesture(handleGesture)

            VStack(alignment: .leading, spacing: 2) {
            // Tap selects (shows the action strip), tap again deselects (hides it); long press (or double-tap) edits the text.
            if focused.wrappedValue != node.id {
                Text(title.isEmpty ? "New item" : title)
                    .font(node.isProject ? .title3.weight(.semibold) : .body)
                    .strikethrough(done)
                    .foregroundStyle(title.isEmpty ? Color.ink.opacity(0.3) : done ? Color.ink.opacity(0.4) : Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { focused.wrappedValue = node.id }
                    .onTapGesture { commit(); toggleSelect() }
                    .onLongPressGesture(minimumDuration: 0.35) { sel.nodeID = node.id; focused.wrappedValue = node.id }
            } else {
            TextField("", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(node.isProject ? .title3.weight(.semibold) : .body)
                .strikethrough(done)
                .foregroundStyle(done ? Color.ink.opacity(0.4) : Color.ink)
                .focused(focused, equals: node.id)
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
                    .onSubmit { commitNote(); focused.wrappedValue = node.id }
            }
            }
            Spacer(minLength: 6)
            marker
            Button { commit(); sel.nodeID = node.id; sel.panel = .review } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink.opacity(0.3))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Details")
            .accessibilityLabel("Details")
            .padding(.top, -3)
        }
        .padding(.vertical, 6)
        .padding(.leading, 6)
        .onAppear { title = node.title; note = node.notes; showNote = !node.notes.isEmpty }
        .onChange(of: node.title) { _, v in if v != title { title = v } }
        .onChange(of: node.notes) { _, v in if v != note { note = v; if !v.isEmpty { showNote = true } } }
        .onChange(of: focused.wrappedValue) { old, new in if new == node.id { sel.nodeID = node.id }; if old == node.id && new != node.id { commit() } }
        if sel.nodeID == node.id || focused.wrappedValue == node.id { actionStrip.padding(.leading, 6 + CGFloat(depth) * 6).padding(.bottom, 8).transition(.opacity) }
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
            Text("\(leafCount.done)/\(leafCount.total)").font(.caption2.monospacedDigit()).foregroundStyle(Color.ink.opacity(0.4)).padding(.top, 3)
        } else if !node.isProject {
            HStack(spacing: 8) {
                if let due = node.due, node.state != .done {
                    Text(due.formatted(.dateTime.month(.abbreviated).day())).font(.caption2).foregroundStyle(due < Date() ? Color.red : Color.ink.opacity(0.45))
                }
                if node.isYourTurn && node.state != .done { Dot(label: "your turn", filled: true) }
            }
            .padding(.top, 3)
        }
    }

    /// The item's actions, on screen (shown under the selected row). Same set as the context menu.
    @ViewBuilder private var actionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                if !node.isProject {
                    group {
                        ForEach(Assignee.allCases) { a in
                            Pill(a == .unassigned ? "—" : a.label, on: node.assignee == a) { store.update(node) { $0.assignee = a }; store.save() }
                        }
                    }
                    group {
                        ForEach(TaskState.allCases) { st in
                            Pill(st == .in_progress ? "doing" : st.label, on: node.state == st) { store.update(node) { $0.state = st }; store.save() }
                        }
                    }
                    group {
                        ForEach(Mode.allCases) { m in
                            Pill(m.glyph, on: node.mode == m, mono: true) { store.update(node) { $0.mode = $0.mode == m ? nil : m }; store.save() }
                                .help(m.rawValue)
                        }
                    }
                }
                group {
                    if !node.isProject {
                        Pill(systemImage: "arrow.left") { onKey(.shiftTab) }.help("Outdent")
                        Pill(systemImage: "arrow.right") { onKey(.tab) }.help("Indent")
                    }
                    Pill(systemImage: "arrow.up") { onKey(.altUp) }.help("Move up")
                    Pill(systemImage: "arrow.down") { onKey(.altDown) }.help("Move down")
                    if hasChildren { Pill(systemImage: node.collapsed ? "chevron.down" : "chevron.up") { store.update(node) { $0.collapsed.toggle() }; store.save() }.help(node.collapsed ? "Expand" : "Collapse") }
                }
                group {
                    Pill(systemImage: "plus") { onKey(.enter) }.help("Add item below")
                    if !node.isProject { Pill(systemImage: "text.alignleft") { openNote() }.help(showNote ? "Edit context" : "Add context") }
                    Pill(systemImage: "info.circle") { sel.nodeID = node.id; sel.panel = .review }.help("Details")
                    Pill(systemImage: "trash") { store.delete(node); store.save() }.help("Delete")
                }
            }
            .padding(.vertical, 2)
        }
    }
    private func group<V: View>(@ViewBuilder _ content: () -> V) -> some View { HStack(spacing: 4) { content() } }

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
                    Button { store.update(node) { $0.mode = m }; store.save() } label: { if node.mode == m { Label("\(m.glyph) · \(m.rawValue)", systemImage: "checkmark") } else { Text("\(m.glyph) · \(m.rawValue)") } }
                }
            }
            Menu("Status") {
                ForEach(TaskState.allCases) { st in
                    Button { store.update(node) { $0.state = st }; store.save() } label: { if node.state == st { Label(st.label, systemImage: "checkmark") } else { Text(st.label) } }
                }
            }
            Divider()
        }
        if hasChildren { Button(node.collapsed ? "Expand" : "Collapse") { store.update(node) { $0.collapsed.toggle() }; store.save() } }
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

/// Small on-screen action: text or symbol; `on` = filled.
struct Pill: View {
    var text: String? = nil
    var systemImage: String? = nil
    var on = false
    var mono = false
    let action: () -> Void
    init(_ text: String, on: Bool = false, mono: Bool = false, action: @escaping () -> Void) { self.text = text; self.on = on; self.mono = mono; self.action = action }
    init(systemImage: String, action: @escaping () -> Void) { self.systemImage = systemImage; self.action = action }
    var body: some View {
        Button(action: action) {
            Group {
                if let t = text { Text(t).font(mono ? .system(size: 11, weight: .semibold, design: .monospaced) : .caption2.weight(.medium)) }
                else if let i = systemImage { Image(systemName: i).font(.system(size: 11, weight: .semibold)) }
            }
            .padding(.horizontal, text == nil ? 7 : 8).padding(.vertical, 4)
            .frame(minWidth: 26)
            .background(on ? Color.ink : Color.ink.opacity(0.06), in: Capsule())
            .foregroundStyle(on ? Color.canvas : Color.ink.opacity(0.8))
        }
        .buttonStyle(.plain)
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
