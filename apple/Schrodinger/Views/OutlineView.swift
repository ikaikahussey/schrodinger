import SwiftUI
import SwiftData

/// One continuous numbered outline. Top-level items are projects; children are numbered within each parent at any depth.
struct OutlineView: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var sel: Selection
    @Query(sort: [SortDescriptor(\Node.position), SortDescriptor(\Node.createdAt)]) private var all: [Node]
    @State private var filter: Filter = .all
    @State private var modeFilter: Mode? = nil
    @FocusState private var focused: UUID?

    enum Filter: String, CaseIterable, Identifiable { case all, mine, ai, review, blocked, week; var id: String { rawValue } }

    private var store: Store { Store(ctx) }
    private var childrenMap: [UUID?: [Node]] { Dictionary(grouping: all, by: { $0.parentID }).mapValues { $0.sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) } } }

    var body: some View {
        let kids = childrenMap
        let roots = kids[nil] ?? []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(roots.enumerated()), id: \.element.id) { i, p in
                    nodeTree(p, depth: 0, index: i, kids: kids)
                }
                Button { let n = store.create(); store.save(); focused = n.id } label: { Label("top-level item", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 8).padding(.top, 6)
            }
            .padding()
        }
        .navigationTitle("Schrodinger")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Picker("Filter", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                Picker("Mode", selection: $modeFilter) { Text("Any mode").tag(Mode?.none); ForEach(Mode.allCases) { Text($0.rawValue).tag(Mode?.some($0)) } }
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

    @ViewBuilder
    private func nodeTree(_ n: Node, depth: Int, index: Int, kids: [UUID?: [Node]]) -> some View {
        let children = kids[n.id] ?? []
        let hidden = (filter != .all || modeFilter != nil) && depth > 0 && !subtreeMatches(n, kids: kids)
        if !hidden {
            NodeRow(node: n, depth: depth, index: index, hasChildren: !children.isEmpty, leafCount: leafCount(n, kids: kids), sel: sel, focused: $focused, onKey: { key in handleKey(key, n, kids: kids) })
            if n.isProject { ProjectMeta(node: n, progress: store.progress(of: n.id), sel: sel).padding(.leading, CGFloat(depth) * 24 + 74) }
            if !n.collapsed {
                ForEach(Array(children.enumerated()), id: \.element.id) { i, c in
                    nodeTree(c, depth: depth + 1, index: i, kids: kids)
                }
                if depth == 0 {
                    Button { let c = store.create(parentID: n.id); store.save(); focused = c.id } label: { Label("item", systemImage: "plus").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, CGFloat(depth + 1) * 24 + 40)
                }
            }
        }
    }

    private func leafCount(_ n: Node, kids: [UUID?: [Node]]) -> (done: Int, total: Int) {
        let c = kids[n.id] ?? []
        if c.isEmpty { return (n.state == .done ? 1 : 0, 1) }
        return c.map { leafCount($0, kids: kids) }.reduce((0, 0)) { ($0.0 + $1.done, $0.1 + $1.total) }
    }

    // Keyboard outlining
    enum Key { case enter, tab, shiftTab, backspaceEmpty, altUp, altDown }
    private func handleKey(_ key: Key, _ n: Node, kids: [UUID?: [Node]]) {
        let s = store
        switch key {
        case .enter:
            let created: Node
            if n.isProject && !(kids[n.id] ?? []).isEmpty && !n.collapsed { created = s.create(parentID: n.id, position: 0) }
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

struct ProjectMeta: View {
    @Bindable var node: Node
    let progress: Store.Progress
    var sel: Selection
    var body: some View {
        HStack(spacing: 10) {
            Text(node.goal.isEmpty ? "set a goal" : node.goal).font(.caption).foregroundStyle(node.goal.isEmpty ? .tertiary : .primary).italic(node.goal.isEmpty)
                .onTapGesture { sel.nodeID = node.id; sel.panel = .review }
            ProgressView(value: Double(progress.pct), total: 100).frame(width: 120)
            Text("\(progress.done)/\(progress.total)").font(.caption).foregroundStyle(.secondary)
            if node.projectStatus != .active { Text(node.projectStatusRaw).font(.caption2).padding(.horizontal, 6).background(.yellow.opacity(0.3), in: Capsule()) }
        }
        .padding(.bottom, 4)
    }
}

/// A single row: number, disclosure, checkbox (leaf tasks), editable title, chips (inline pickers), due, last activity.
struct NodeRow: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var node: Node
    let depth: Int
    let index: Int
    let hasChildren: Bool
    let leafCount: (done: Int, total: Int)
    var sel: Selection
    var focused: FocusState<UUID?>.Binding
    let onKey: (OutlineView.Key) -> Void
    @State private var title: String = ""

    private var store: Store { Store(ctx) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(depth == 0 ? .primary : .secondary).fontWeight(depth == 0 ? .semibold : .regular).frame(width: 26, alignment: .trailing)
            Button { store.update(node) { $0.collapsed.toggle() }; store.save() } label: { Image(systemName: node.collapsed ? "chevron.right" : "chevron.down").font(.caption2) }
                .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hasChildren ? 1 : 0).frame(width: 14)
            if !node.isProject && !hasChildren {
                Button { store.update(node) { $0.state = $0.state == .done ? .todo : .done }; store.save() } label: {
                    Image(systemName: node.state == .done ? "checkmark.square.fill" : "square").foregroundStyle(node.state == .done ? Color.accentColor : .secondary)
                }.buttonStyle(.plain)
            }
            TextField("", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(node.isProject ? .headline : .body)
                .strikethrough(node.state == .done && !hasChildren)
                .foregroundStyle(node.state == .done && !hasChildren ? .secondary : .primary)
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
            Spacer(minLength: 4)
            if !node.isProject && hasChildren {
                Text("\(leafCount.done)/\(leafCount.total)").font(.caption).foregroundStyle(.secondary)
            } else if !node.isProject {
                Menu { ForEach(Assignee.allCases) { a in Button(a.label) { store.update(node) { $0.assignee = a }; store.save() } } } label: {
                    Chip(text: node.assignee.label, color: chipColor(node.assignee), dashed: node.isYourTurn)
                }.menuStyle(.borderlessButton).fixedSize()
                Menu {
                    Button("none") { store.update(node) { $0.mode = nil }; store.save() }
                    ForEach(Mode.allCases) { m in Button(m.rawValue) { store.update(node) { $0.mode = m }; store.save() } }
                } label: { Chip(text: node.mode?.rawValue ?? "#mode", color: .orange, faded: node.mode == nil) }.menuStyle(.borderlessButton).fixedSize()
                Menu { ForEach(TaskState.allCases) { st in Button(st.label) { store.update(node) { $0.state = st }; store.save() } } } label: {
                    Chip(text: node.state.label, color: stateColor(node.state))
                }.menuStyle(.borderlessButton).fixedSize()
                if let due = node.due {
                    Text(due.dayString).font(.caption).foregroundStyle(due < Date() && node.state != .done ? .red : .secondary)
                }
            }
            #if os(iOS)
            Menu {
                Button("Add item below") { onKey(.enter) }
                Button("Indent") { onKey(.tab) }.disabled(index == 0)
                Button("Outdent") { onKey(.shiftTab) }.disabled(node.isProject)
                Button("Move up") { onKey(.altUp) }
                Button("Move down") { onKey(.altDown) }
                Button("Details") { sel.nodeID = node.id; sel.panel = .review }
                Button("Delete", role: .destructive) { store.delete(node); store.save() }
            } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }.fixedSize()
            #endif
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .padding(.leading, CGFloat(depth) * 24)
        .background(sel.nodeID == node.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Details") { sel.nodeID = node.id; sel.panel = .review }
            Button("Delete", role: .destructive) { store.delete(node); store.save() }
        }
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
    private func chipColor(_ a: Assignee) -> Color { switch a { case .human: .green; case .ai: .blue; case .shared: .purple; case .unassigned: .gray } }
    private func stateColor(_ s: TaskState) -> Color { switch s { case .review: .purple; case .blocked: .yellow; case .in_progress: .cyan; default: .gray } }
}

struct Chip: View {
    let text: String
    let color: Color
    var faded = false
    var dashed = false
    var body: some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(dashed ? 0.9 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .foregroundStyle(color).opacity(faded ? 0.5 : 1)
    }
}

