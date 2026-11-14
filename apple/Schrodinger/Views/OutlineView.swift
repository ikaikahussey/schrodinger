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
        }
        .background(Color.canvas)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { Text("Schrodinger").font(.headline) }
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
            NodeRow(node: n, depth: depth, hasChildren: !children.isEmpty, leafCount: leafCount(n, kids: kids), sel: sel, focused: $focused, onKey: { key in handleKey(key, n, kids: kids) })
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
    let onKey: (OutlineView.Key) -> Void
    @State private var title: String = ""

    private var store: Store { Store(ctx) }
    private var isLeafTask: Bool { !node.isProject && !hasChildren }
    private var done: Bool { node.state == .done && isLeafTask }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Menu { menu } label: {
                DepthBars(node: node, depth: depth, hasChildren: hasChildren)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .padding(.top, 3)
            .help(summary)
            .accessibilityLabel(summary)

            TextField("", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(node.isProject ? .title3.weight(.semibold) : .body)
                .strikethrough(done)
                .foregroundStyle(done ? Color.ink.opacity(0.4) : Color.ink)
                .focused(focused, equals: node.id)
                .onAppear { title = node.title }
                .onChange(of: node.title) { _, v in if v != title { title = v } }
                .onSubmit { commit(); onKey(.enter) }
                .onChange(of: focused.wrappedValue) { old, new in if old == node.id && new != node.id { commit() } }
                .onTapGesture { sel.nodeID = node.id }
                #if os(macOS)
                .onKeyPress(.tab) { commit(); onKey(.tab); return .handled }
                .onKeyPress(.tab, phases: .down) { press in if press.modifiers.contains(.shift) { commit(); onKey(.shiftTab); return .handled }; return .ignored }
                .onKeyPress(.delete) { if title.isEmpty { onKey(.backspaceEmpty); return .handled }; return .ignored }
                .onKeyPress(.upArrow, phases: .down) { p in if p.modifiers.contains(.option) { commit(); onKey(.altUp); return .handled }; return .ignored }
                .onKeyPress(.downArrow, phases: .down) { p in if p.modifiers.contains(.option) { commit(); onKey(.altDown); return .handled }; return .ignored }
                #endif
            Spacer(minLength: 6)
            marker
        }
        .padding(.vertical, 6)
        .padding(.leading, 6)
        .background(sel.nodeID == node.id ? Color.ink.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu { menu }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            if isLeafTask { Button(done ? "Undo" : "Done") { store.update(node) { $0.state = done ? .todo : .done }; store.save() }.tint(.black) }
            Button("Details") { sel.nodeID = node.id; sel.panel = .review }.tint(.gray)
        }
        .swipeActions(edge: .leading) {
            Button("Indent") { onKey(.tab) }.tint(.gray)
            Button("Outdent") { onKey(.shiftTab) }.tint(.gray).disabled(node.isProject)
        }
        #endif
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
            Button("Indent") { onKey(.tab) }
            Button("Outdent") { onKey(.shiftTab) }
        }
        Button("Move up") { onKey(.altUp) }
        Button("Move down") { onKey(.altDown) }
        Button("Add item below") { onKey(.enter) }
        Divider()
        Button("Details") { sel.nodeID = node.id; sel.panel = .review }
        Button("Delete", role: .destructive) { store.delete(node); store.save() }
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
