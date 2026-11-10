import Foundation
import SwiftData

/// All reads/writes go through here so the harness and the UI share one set of rules.
/// Not thread-safe by itself: use it on the ModelContext's actor (MainActor for the UI's context).
struct Store {
    let ctx: ModelContext
    init(_ ctx: ModelContext) { self.ctx = ctx }

    // MARK: - Fetch helpers
    func node(_ id: UUID) -> Node? {
        var d = FetchDescriptor<Node>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1
        return try? ctx.fetch(d).first
    }
    func allNodes() -> [Node] {
        (try? ctx.fetch(FetchDescriptor<Node>(sortBy: [SortDescriptor(\.position), SortDescriptor(\.createdAt)]))) ?? []
    }
    func children(of parentID: UUID?) -> [Node] {
        let d: FetchDescriptor<Node>
        if let parentID { d = FetchDescriptor(predicate: #Predicate { $0.parentID == parentID }, sortBy: [SortDescriptor(\.position), SortDescriptor(\.createdAt)]) }
        else { d = FetchDescriptor(predicate: #Predicate { $0.parentID == nil }, sortBy: [SortDescriptor(\.position), SortDescriptor(\.createdAt)]) }
        return (try? ctx.fetch(d)) ?? []
    }
    func projects() -> [Node] { children(of: nil) }
    func descendants(of id: UUID) -> [Node] {
        var out: [Node] = []
        var queue = children(of: id)
        while !queue.isEmpty { let n = queue.removeFirst(); out.append(n); queue.append(contentsOf: children(of: n.id)) }
        return out
    }
    func project(of n: Node) -> Node {
        var cur = n
        while let p = cur.parentID, let parent = node(p) { cur = parent }
        return cur
    }
    func leaves(under id: UUID) -> [Node] {
        let desc = descendants(of: id)
        let parents = Set(desc.compactMap(\.parentID))
        return desc.filter { !parents.contains($0.id) }
    }
    struct Progress { let total: Int; let done: Int; var pct: Int { total == 0 ? 0 : Int((Double(done) / Double(total) * 100).rounded()) } }
    func progress(of id: UUID) -> Progress {
        let l = leaves(under: id)
        return Progress(total: l.count, done: l.filter { $0.state == .done }.count)
    }
    func depsSatisfied(_ n: Node) -> Bool { n.deps.allSatisfy { node($0)?.state == .done } }

    // MARK: - Activity
    @discardableResult
    func log(_ n: Node, _ actor: Actor, _ action: String, _ detail: String = "", undo: [String: Any]? = nil) -> ActivityEntry {
        let a = ActivityEntry(nodeID: n.id, actor: actor, action: action, detail: detail, undo: undo)
        ctx.insert(a); n.lastActivityAt = Date()
        return a
    }
    func activity(for id: UUID, limit: Int = 50) -> [ActivityEntry] {
        var d = FetchDescriptor<ActivityEntry>(predicate: #Predicate { $0.nodeID == id }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)]); d.fetchLimit = limit
        return (try? ctx.fetch(d)) ?? []
    }
    func recentActivity(limit: Int = 100) -> [ActivityEntry] {
        var d = FetchDescriptor<ActivityEntry>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]); d.fetchLimit = limit
        return (try? ctx.fetch(d)) ?? []
    }
    func lastActivity(for id: UUID) -> ActivityEntry? { activity(for: id, limit: 1).first }

    // MARK: - Mutations
    @discardableResult
    func create(title: String = "", parentID: UUID? = nil, assignee: Assignee? = nil, mode: Mode? = nil, due: Date? = nil, position: Int? = nil, actor: Actor = .human) -> Node {
        let siblings = children(of: parentID)
        let n = Node(title: title, parentID: parentID, assignee: assignee, mode: mode, due: due, position: position ?? siblings.count)
        if let position { for s in siblings where s.position >= position { s.position += 1 } }
        ctx.insert(n)
        log(n, actor, "create", title)
        return n
    }

    /// Apply a patch with undo recorded. Only the keys given are changed.
    func update(_ n: Node, actor: Actor = .human, detail: String = "", _ patch: (Node) -> Void) {
        let before: [String: Any] = ["title": n.title, "assignee": n.assigneeRaw, "state": n.stateRaw, "mode": n.modeRaw, "ai_status": n.aiStatusRaw,
                                     "due": n.due?.timeIntervalSince1970 as Any, "acceptance_note": n.acceptanceNote, "artifact": n.artifact as Any,
                                     "goal": n.goal, "success_criteria": n.successCriteria, "constraints": n.constraints, "project_status": n.projectStatusRaw,
                                     "deps": n.deps.map(\.uuidString)]
        patch(n)
        n.updatedAt = Date()
        var changed: [String] = []
        if before["title"] as? String != n.title { changed.append("title") }
        if before["assignee"] as? String != n.assigneeRaw { changed.append("assignee: \(before["assignee"] ?? "") → \(n.assigneeRaw)") }
        if before["state"] as? String != n.stateRaw { changed.append("state: \(before["state"] ?? "") → \(n.stateRaw)") }
        if before["mode"] as? String != n.modeRaw { changed.append("mode: \(n.modeRaw)") }
        if before["ai_status"] as? String != n.aiStatusRaw { changed.append("ai: \(n.aiStatusRaw)") }
        if (before["due"] as? Double) != n.due?.timeIntervalSince1970 { changed.append("due") }
        if before["acceptance_note"] as? String != n.acceptanceNote { changed.append("note") }
        if (before["artifact"] as? String) != n.artifact { changed.append("artifact") }
        if before["goal"] as? String != n.goal { changed.append("goal") }
        if before["project_status"] as? String != n.projectStatusRaw { changed.append("status: \(n.projectStatusRaw)") }
        if (before["deps"] as? [String]) != n.deps.map(\.uuidString) { changed.append("deps") }
        if !changed.isEmpty { log(n, actor, "update", detail.isEmpty ? changed.joined(separator: "; ") : detail, undo: before) }
    }

    func applyUndo(_ a: ActivityEntry) throws {
        guard let n = node(a.nodeID), let u = a.undo else { throw StoreError.nothingToUndo }
        if a.action == "move" {
            let parent = (u["parent_id"] as? String).flatMap(UUID.init(uuidString:))
            try move(n, to: parent, position: u["position"] as? Int ?? 0)
            return
        }
        update(n, actor: .human, detail: "undo") { n in
            if let v = u["title"] as? String { n.title = v }
            if let v = u["assignee"] as? String { n.assigneeRaw = v }
            if let v = u["state"] as? String { n.stateRaw = v }
            if let v = u["mode"] as? String { n.modeRaw = v }
            if let v = u["ai_status"] as? String { n.aiStatusRaw = v }
            if let v = u["due"] as? Double { n.due = Date(timeIntervalSince1970: v) } else { n.due = nil }
            if let v = u["acceptance_note"] as? String { n.acceptanceNote = v }
            n.artifact = u["artifact"] as? String
            if let v = u["goal"] as? String { n.goal = v }
            if let v = u["success_criteria"] as? String { n.successCriteria = v }
            if let v = u["constraints"] as? String { n.constraints = v }
            if let v = u["project_status"] as? String { n.projectStatusRaw = v }
            if let v = u["deps"] as? [String] { n.deps = v.compactMap(UUID.init(uuidString:)) }
        }
    }

    func move(_ n: Node, to parentID: UUID?, position: Int, actor: Actor = .human) throws {
        if parentID == n.id || descendants(of: n.id).contains(where: { $0.id == parentID }) { throw StoreError.invalidMove }
        let oldParent = n.parentID, oldPos = n.position
        var siblings = children(of: parentID).filter { $0.id != n.id }
        siblings.insert(n, at: max(0, min(position, siblings.count)))
        for (i, s) in siblings.enumerated() { s.position = i }
        n.parentID = parentID
        if n.isProject { n.assigneeRaw = Assignee.unassigned.rawValue }
        if oldParent != parentID { for (i, s) in children(of: oldParent).filter({ $0.id != n.id }).enumerated() { s.position = i } }
        n.updatedAt = Date()
        log(n, actor, "move", "→ \(parentID?.uuidString.prefix(8) ?? "root") @\(position)", undo: ["parent_id": oldParent?.uuidString as Any, "position": oldPos])
    }

    func delete(_ n: Node) {
        for d in descendants(of: n.id) { ctx.delete(d) }
        for a in activity(for: n.id, limit: 10_000) { ctx.delete(a) }
        let parent = n.parentID
        ctx.delete(n)
        for (i, s) in children(of: parent).enumerated() { s.position = i }
    }

    // MARK: - Review / shared flow
    func approve(_ n: Node) throws {
        guard n.state == .review else { throw StoreError.notInReview }
        update(n, detail: "approved") { $0.state = .done }
    }
    func reject(_ n: Node, note: String) throws {
        guard n.state == .review else { throw StoreError.notInReview }
        update(n, detail: "rejected: \(note)") { x in
            x.state = .todo
            x.acceptanceNote = [x.acceptanceNote, note.isEmpty ? "" : "[rejected \(Date().dayString)] \(note)"].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }
    func sendBackToAI(_ n: Node, note: String) throws {
        guard n.assignee == .shared else { throw StoreError.notShared }
        update(n, detail: "sent back to AI: \(note)") { x in
            x.aiStatus = .pending
            x.acceptanceNote = [x.acceptanceNote, note.isEmpty ? "" : "[sent back \(Date().dayString)] \(note)"].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    // MARK: - Inbox
    @discardableResult
    func propose(projectID: UUID, nodeID: UUID?, type: ProposalType, summary: String, payload: [String: Any] = [:]) -> Proposal? {
        // Never re-raise an identical proposal (open, accepted or dismissed).
        let t = type.rawValue
        let existing = (try? ctx.fetch(FetchDescriptor<Proposal>(predicate: #Predicate { $0.projectID == projectID && $0.typeRaw == t && $0.summary == summary }))) ?? []
        if existing.contains(where: { $0.nodeID == nodeID }) { return nil }
        let p = Proposal(projectID: projectID, nodeID: nodeID, type: type, summary: summary, payload: payload)
        ctx.insert(p)
        return p
    }
    func inbox() -> [Proposal] {
        let open = ProposalStatus.open.rawValue
        return (try? ctx.fetch(FetchDescriptor<Proposal>(predicate: #Predicate { $0.statusRaw == open }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }
    func accept(_ p: Proposal) throws {
        guard p.status == .open else { throw StoreError.proposalClosed }
        let pl = p.payload
        switch p.type {
        case .new_task:
            let parent = (pl["parent_id"] as? String).flatMap(UUID.init(uuidString:)) ?? p.projectID
            let due = (pl["due"] as? Double).map { Date(timeIntervalSince1970: $0) }
            create(title: pl["title"] as? String ?? "", parentID: parent, assignee: Assignee(rawValue: pl["assignee"] as? String ?? "ai"), mode: Mode(rawValue: pl["mode"] as? String ?? ""), due: due, actor: .ai)
        case .decompose:
            for t in pl["subtasks"] as? [[String: Any]] ?? [] {
                create(title: t["title"] as? String ?? "", parentID: p.nodeID, assignee: Assignee(rawValue: t["assignee"] as? String ?? "ai"), actor: .ai)
            }
        case .reassign:
            if let id = p.nodeID, let n = node(id), let a = Assignee(rawValue: pl["assignee"] as? String ?? "") { update(n, actor: .ai, detail: "reassigned (proposal accepted)") { $0.assignee = a } }
        case .stale, .blocked_chain, .no_path: break
        }
        p.status = .accepted
    }
    func dismiss(_ p: Proposal) { p.status = .dismissed }

    // MARK: - Digests, files, runs
    func saveDigest(projectID: UUID, day: String, body: String) {
        if let d = (try? ctx.fetch(FetchDescriptor<Digest>(predicate: #Predicate { $0.projectID == projectID && $0.day == day })))?.first { d.body = body; d.createdAt = Date() }
        else { ctx.insert(Digest(projectID: projectID, day: day, body: body)) }
    }
    func digests(for projectID: UUID, limit: Int = 7) -> [Digest] {
        var d = FetchDescriptor<Digest>(predicate: #Predicate { $0.projectID == projectID }, sortBy: [SortDescriptor(\.day, order: .reverse)]); d.fetchLimit = limit
        return (try? ctx.fetch(d)) ?? []
    }
    func files(for projectID: UUID) -> [WorkspaceFile] {
        (try? ctx.fetch(FetchDescriptor<WorkspaceFile>(predicate: #Predicate { $0.projectID == projectID }, sortBy: [SortDescriptor(\.path)]))) ?? []
    }
    func file(_ projectID: UUID, _ path: String) -> WorkspaceFile? { files(for: projectID).first { $0.path == path } }
    func writeFile(_ projectID: UUID, _ path: String, _ content: String) {
        if let f = file(projectID, path) { f.content = content; f.updatedAt = Date() } else { ctx.insert(WorkspaceFile(projectID: projectID, path: path, content: content)) }
    }
    func startRun(projectID: UUID?) -> HarnessRun { let r = HarnessRun(projectID: projectID); ctx.insert(r); return r }
    func runs(limit: Int = 20) -> [HarnessRun] {
        var d = FetchDescriptor<HarnessRun>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]); d.fetchLimit = limit
        return (try? ctx.fetch(d)) ?? []
    }

    // MARK: - Batch by mode (open leaf tasks across active projects)
    func byMode(assignee: Assignee? = nil) -> [(mode: String, tasks: [(Node, project: Node)])] {
        var rows: [(Node, Node)] = []
        for p in projects() where p.projectStatus == .active {
            for t in leaves(under: p.id) where t.state != .done {
                let include: Bool = switch assignee {
                case .human: t.assignee == .human || t.isYourTurn
                case .ai: t.assignee == .ai || (t.assignee == .shared && t.aiStatus == .pending)
                case .some(let a): t.assignee == a
                case nil: true
                }
                if include { rows.append((t, p)) }
            }
        }
        let grouped = Dictionary(grouping: rows, by: { $0.0.modeRaw })
        let order = Mode.allCases.map(\.rawValue) + [""]
        return order.compactMap { m in
            guard let g = grouped[m], !g.isEmpty else { return nil }
            let sorted = g.sorted { ($0.0.due ?? .distantFuture, $0.1.position, $0.0.position) < ($1.0.due ?? .distantFuture, $1.1.position, $1.0.position) }
            return (mode: m.isEmpty ? "unsorted" : m, tasks: sorted.map { ($0.0, project: $0.1) })
        }
    }

    func save() { try? ctx.save() }
}

enum StoreError: LocalizedError {
    case invalidMove, notInReview, notShared, proposalClosed, nothingToUndo
    var errorDescription: String? {
        switch self {
        case .invalidMove: "Cannot move an item into its own subtree"
        case .notInReview: "Task is not in review"
        case .notShared: "Task is not shared"
        case .proposalClosed: "Proposal is not open"
        case .nothingToUndo: "Nothing to undo"
        }
    }
}
