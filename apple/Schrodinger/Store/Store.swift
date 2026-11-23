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

    // MARK: - Attachments (photos and links on an item)
    func attachments(for nodeID: UUID) -> [Attachment] {
        let item = Attachment.Kind.item.rawValue   // links between items are not attachments: see itemLinks(of:)
        return (try? ctx.fetch(FetchDescriptor<Attachment>(predicate: #Predicate { $0.nodeID == nodeID && $0.kindRaw != item }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }
    @discardableResult
    func addPhoto(_ data: Data, to nodeID: UUID) -> Attachment {
        let a = Attachment(nodeID: nodeID, kind: .photo, data: data)
        ctx.insert(a)
        return a
    }
    /// Adds a link from typed or pasted text. Returns nil (and adds nothing) if the text is not a web address.
    @discardableResult
    func addLink(_ text: String, to nodeID: UUID) -> Attachment? {
        guard let url = Attachment.normalizedURL(text) else { return nil }
        let a = Attachment(nodeID: nodeID, kind: .link, urlString: url.absoluteString)
        ctx.insert(a)
        return a
    }
    func deleteAttachment(_ a: Attachment) { ctx.delete(a) }

    // MARK: - Links between two items
    /// Every link the item is part of, oldest first. A link has no direction: it is found from either of its items.
    func itemLinks(of id: UUID) -> [Attachment] {
        let item = Attachment.Kind.item.rawValue, other = id.uuidString
        let made = (try? ctx.fetch(FetchDescriptor<Attachment>(predicate: #Predicate { $0.kindRaw == item && $0.nodeID == id }))) ?? []
        let received = (try? ctx.fetch(FetchDescriptor<Attachment>(predicate: #Predicate { $0.kindRaw == item && $0.urlString == other }))) ?? []
        return (made + received).sorted { $0.createdAt < $1.createdAt }
    }
    /// The items linked to this one (links whose other item no longer exists are skipped).
    func linkedItems(of id: UUID) -> [Node] { itemLinks(of: id).compactMap { $0.otherEnd(from: id) }.compactMap { node($0) } }
    /// Links two items. Returns the link (the existing one if they were already linked); nil if they are the same
    /// item or either does not exist.
    @discardableResult
    func link(_ a: UUID, _ b: UUID) -> Attachment? {
        guard a != b, node(a) != nil, node(b) != nil else { return nil }
        if let existing = itemLinks(of: a).first(where: { $0.otherEnd(from: a) == b }) { return existing }
        let l = Attachment(nodeID: a, kind: .item, urlString: b.uuidString)
        ctx.insert(l)
        return l
    }
    /// Removes the link between two items, from either side.
    func unlink(_ a: UUID, _ b: UUID) {
        for l in itemLinks(of: a) where l.otherEnd(from: a) == b { ctx.delete(l) }
    }
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
    func create(title: String = "", parentID: UUID? = nil, assignee: Assignee? = nil, due: Date? = nil, position: Int? = nil, actor: Actor = .human) -> Node {
        let siblings = children(of: parentID)
        let n = Node(title: title, parentID: parentID, assignee: assignee, due: due, position: position ?? siblings.count)
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

    /// Deletes an item. `keepChildren`: its children first move up a level, into its place among its siblings.
    func delete(_ n: Node, keepChildren: Bool, actor: Actor = .human) {
        if keepChildren {
            let at = children(of: n.parentID).firstIndex { $0.id == n.id } ?? 0
            for (i, c) in children(of: n.id).enumerated() { try? move(c, to: n.parentID, position: at + 1 + i) }
        }
        delete(n, actor: actor)
    }

    /// Deletes an item and everything under it. Each deleted item leaves one "delete" entry behind (its text and
    /// where it was), which is what History shows struck through; the rest of its activity goes with it.
    func delete(_ n: Node, actor: Actor = .human) {
        let victims = [n] + descendants(of: n.id)
        // Events made for the deleted items go with them.
        let events = victims.map(\.calendarEventID).filter { !$0.isEmpty }
        if !events.isEmpty { Task { await CalendarService.shared.remove(eventIDs: events) } }
        // Links to and from the deleted items go too (collected by id: a link between two of them is found twice).
        var links: [UUID: Attachment] = [:]
        for v in victims { for l in itemLinks(of: v.id) { links[l.id] = l } }
        for l in links.values { ctx.delete(l) }
        let parent = n.parentID
        for v in victims {
            for f in attachments(for: v.id) { ctx.delete(f) }
            for a in activity(for: v.id, limit: 10_000) { ctx.delete(a) }
            ctx.insert(ActivityEntry(nodeID: v.id, actor: actor, action: HistoryAction.delete, detail: v.title, undo: [
                "title": v.title, "parent_id": v.parentID?.uuidString as Any, "position": v.position,
                "state": v.stateRaw, "created_at": v.createdAt.timeIntervalSince1970,
                // Enough to bring the item back as it was (see `reinstate`).
                "notes": v.notes, "goal": v.goal, "assignee": v.assigneeRaw, "due": v.due?.timeIntervalSince1970 as Any,
                "acceptance_note": v.acceptanceNote, "artifact": v.artifact as Any, "project_status": v.projectStatusRaw,
                "success_criteria": v.successCriteria, "constraints": v.constraints]))
            ctx.delete(v)
        }
        for (i, s) in children(of: parent).filter({ $0.id != n.id }).enumerated() { s.position = i }
    }

    /// Brings a deleted item back where it was, along with the items under it that were deleted with it. If the
    /// item it was under has been deleted too, that one comes back first (without its other children). Text, notes,
    /// status, holder and date return; photos, links and calendar events of the deleted item do not.
    /// Returns nil if there is no record of the item.
    @discardableResult
    func reinstate(_ id: UUID, actor: Actor = .human) -> Node? {
        if let live = node(id) { return live }
        let del = HistoryAction.delete
        let entries = (try? ctx.fetch(FetchDescriptor<ActivityEntry>(predicate: #Predicate { $0.action == del }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        var tombs: [UUID: ActivityEntry] = [:]
        for e in entries { tombs[e.nodeID] = e }
        guard let first = tombs[id] else { return nil }
        // Items deleted in the same stroke as this one (not ones removed from under it earlier).
        let cutoff = first.createdAt.addingTimeInterval(-2)

        func parentID(_ t: ActivityEntry) -> UUID? { (t.undo?["parent_id"] as? String).flatMap(UUID.init(uuidString:)) }
        func revive(_ t: ActivityEntry) -> Node {
            tombs[t.nodeID] = nil
            let u = t.undo ?? [:]
            var parent = parentID(t)
            if let p = parent, node(p) == nil {
                if let pt = tombs[p] { _ = revive(pt) } else { parent = nil }
            }
            let siblings = children(of: parent)
            let at = max(0, min(u["position"] as? Int ?? siblings.count, siblings.count))
            for s in siblings where s.position >= at { s.position += 1 }
            let n = Node(title: u["title"] as? String ?? t.detail, parentID: parent, position: at)
            n.id = t.nodeID
            if let v = u["state"] as? String { n.stateRaw = v }
            if let v = u["assignee"] as? String, parent != nil { n.assigneeRaw = v }
            if let v = u["notes"] as? String { n.notes = v }
            if let v = u["goal"] as? String { n.goal = v }
            if let v = u["due"] as? Double { n.due = Date(timeIntervalSince1970: v) }
            if let v = u["acceptance_note"] as? String { n.acceptanceNote = v }
            n.artifact = u["artifact"] as? String
            if let v = u["project_status"] as? String { n.projectStatusRaw = v }
            if let v = u["success_criteria"] as? String { n.successCriteria = v }
            if let v = u["constraints"] as? String { n.constraints = v }
            if let v = u["created_at"] as? Double { n.createdAt = Date(timeIntervalSince1970: v) }
            ctx.insert(n)
            ctx.delete(t)
            log(n, actor, HistoryAction.restore, n.title)
            return n
        }

        let top = revive(first)
        var queue = [id]
        while !queue.isEmpty {
            let cur = queue.removeFirst()
            let under = tombs.values.filter { parentID($0) == cur && $0.createdAt >= cutoff }
                .sorted { ($0.undo?["position"] as? Int ?? 0) < ($1.undo?["position"] as? Int ?? 0) }
            for t in under { let n = revive(t); queue.append(n.id) }
        }
        return top
    }

    // MARK: - History (what was added, deleted, renamed, completed or moved since a date)
    /// The outline as History mode shows it: every current item in outline order, plus the items deleted since `since`
    /// in the place they used to be. Each row says what happened to it in that time. `changesOnly` leaves out
    /// items that did not change (their changed descendants keep them in, for context).
    func history(since: Date, changesOnly: Bool = false) -> [HistoryRow] {
        let nodes = allNodes()
        let live = Set(nodes.map(\.id))
        let d = FetchDescriptor<ActivityEntry>(predicate: #Predicate { $0.createdAt >= since }, sortBy: [SortDescriptor(\.createdAt)])
        let entries = (try? ctx.fetch(d)) ?? []
        var byNode: [UUID: [ActivityEntry]] = [:]
        for e in entries { byNode[e.nodeID, default: []].append(e) }

        struct Item { let row: HistoryRow; let parentID: UUID?; let position: Int }
        var items: [Item] = []
        for n in nodes {
            let es = byNode[n.id] ?? []
            var changes: Set<HistoryChange> = []
            var oldTitle: String? = nil
            let added = n.createdAt >= since || es.contains { $0.action == "create" }
            if added { changes.insert(.added) }
            else {
                // Renamed: its text at the start of the period (from the first change that recorded it) differs from now.
                if let first = es.first(where: { $0.action == "update" && $0.undo?["title"] is String }),
                   let was = first.undo?["title"] as? String, was != n.title {
                    if was.isEmpty { changes.insert(.edited) } else { changes.insert(.renamed); oldTitle = was }
                }
                // Moved: under a different item than at the start of the period (reordering in place does not count).
                if let first = es.first(where: { $0.action == "move" }), let u = first.undo,
                   (u["parent_id"] as? String).flatMap(UUID.init(uuidString:)) != n.parentID { changes.insert(.moved) }
            }
            // Completed: done now, and not done at the start of the period.
            if n.state == .done, let first = es.first(where: { $0.action == "update" && $0.undo?["state"] is String }),
               first.undo?["state"] as? String != TaskState.done.rawValue { changes.insert(.completed) }
            else if n.state == .done && added && !n.isProject { changes.insert(.completed) }
            if changes.isEmpty && es.contains(where: { $0.action == "update" }) { changes.insert(.edited) }
            let when = es.last?.createdAt ?? (added ? n.createdAt : nil)
            items.append(Item(row: HistoryRow(id: n.id, depth: 0, title: n.title, oldTitle: oldTitle, changes: changes, when: when, done: n.state == .done, deleted: false),
                              parentID: n.parentID, position: n.position))
        }
        // Deleted items. An item typed and removed again with no text leaves nothing to show.
        let tombs = entries.filter { $0.action == HistoryAction.delete && !live.contains($0.nodeID) && !$0.detail.trimmingCharacters(in: .whitespaces).isEmpty }
        let tombIDs = Set(tombs.map(\.nodeID))
        for t in tombs {
            let u = t.undo ?? [:]
            var parent = (u["parent_id"] as? String).flatMap(UUID.init(uuidString:))
            // Its parent is gone and out of the period: show it at the top level.
            if let p = parent, !live.contains(p), !tombIDs.contains(p) { parent = nil }
            items.append(Item(row: HistoryRow(id: t.nodeID, depth: 0, title: t.detail, oldTitle: nil, changes: [.deleted], when: t.createdAt,
                                              done: u["state"] as? String == TaskState.done.rawValue, deleted: true),
                              parentID: parent, position: u["position"] as? Int ?? 0))
        }
        // A deleted item sorts just before the item that now has its old place.
        let kids = Dictionary(grouping: items, by: { $0.parentID }).mapValues { g in
            g.sorted { a, b in
                if a.position != b.position { return a.position < b.position }
                if a.row.deleted != b.row.deleted { return a.row.deleted }
                return (a.row.when ?? .distantPast) < (b.row.when ?? .distantPast)
            }
        }
        var out: [HistoryRow] = []
        var seen: Set<UUID> = []
        @discardableResult func walk(_ parent: UUID?, _ depth: Int) -> Bool {
            var any = false
            for it in kids[parent] ?? [] where !seen.contains(it.row.id) {
                seen.insert(it.row.id)
                let at = out.count
                var row = it.row; row.depth = depth
                row.parentID = parent; row.position = it.position
                out.append(row)
                let below = walk(it.row.id, depth + 1)
                if changesOnly && row.changes.isEmpty && !below { out.removeSubrange(at...) } else { any = true }
            }
            return any
        }
        walk(nil, 0)
        return out
    }

    /// Deleted-item entries older than `days` are dropped (History reaches back that far at most). Run at launch.
    @discardableResult
    func pruneHistory(olderThan days: Int = 90, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let del = HistoryAction.delete
        let d = FetchDescriptor<ActivityEntry>(predicate: #Predicate { $0.action == del && $0.createdAt < cutoff })
        let old = (try? ctx.fetch(d)) ?? []
        for a in old { ctx.delete(a) }
        if !old.isEmpty { save() }
        return old.count
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
            let made = create(title: pl["title"] as? String ?? "", parentID: parent, assignee: Assignee(rawValue: pl["assignee"] as? String ?? "ai"), due: due, actor: .ai)
            // Tags the proposal carries ("tags", or the older "mode") go in the new item's notes.
            let tags = ((pl["tags"] as? [String]) ?? []) + [pl["mode"] as? String].compactMap { $0 }
            if !tags.isEmpty { made.notes = tags.map { "#" + $0 }.joined(separator: " ") }
        case .decompose:
            for t in pl["subtasks"] as? [[String: Any]] ?? [] {
                create(title: t["title"] as? String ?? "", parentID: p.nodeID, assignee: Assignee(rawValue: t["assignee"] as? String ?? "ai"), actor: .ai)
            }
        case .reassign:
            if let id = p.nodeID, let n = node(id), let a = Assignee(rawValue: pl["assignee"] as? String ?? "") { update(n, actor: .ai, detail: "reassigned (proposal accepted)") { $0.assignee = a } }
        case .retitle:
            if let id = p.nodeID, let n = node(id), let t = pl["title"] as? String, !t.isEmpty { update(n, actor: .ai, detail: "reworded (suggestion accepted)") { $0.title = t } }
        case .note:
            if let id = p.nodeID, let n = node(id), let t = pl["text"] as? String, !t.isEmpty {
                // Same place the row's notes field edits: a task's notes; for a top-level item, its goal.
                update(n, actor: .ai, detail: "note added (suggestion accepted)") { n in
                    if n.isProject { n.goal = n.goal.isEmpty ? t : n.goal + "\n" + t } else { n.notes = n.notes.isEmpty ? t : n.notes + "\n" + t }
                }
            }
        case .stale, .blocked_chain, .no_path, .feedback: break
        }
        p.status = .accepted
    }
    func dismiss(_ p: Proposal) { p.status = .dismissed }
    /// Closes the stale / blocked / no-open-tasks notices an earlier version filed on its own. Nothing files them now.
    func dismissAutomaticNotices() {
        let auto: Set<ProposalType> = [.stale, .blocked_chain, .no_path]
        let open = inbox().filter { auto.contains($0.type) }
        guard !open.isEmpty else { return }
        for p in open { dismiss(p) }
        save()
    }

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

    // MARK: - Batch by tag (open leaf tasks across active projects)
    /// Open tasks in active projects, grouped by tag (a task with several tags is in each group), then untagged.
    func byTag(assignee: Assignee? = nil) -> [(tag: String, tasks: [(Node, project: Node)])] {
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
        var groups: [String: [(Node, Node)]] = [:]
        for r in rows { let tags = r.0.tags; for t in tags.isEmpty ? [""] : Array(tags) { groups[t, default: []].append(r) } }
        let order = groups.keys.filter { !$0.isEmpty }.sorted() + (groups[""] == nil ? [] : [""])
        return order.map { tag in
            let sorted = groups[tag]!.sorted { ($0.0.due ?? .distantFuture, $0.1.position, $0.0.position) < ($1.0.due ?? .distantFuture, $1.1.position, $1.0.position) }
            return (tag: tag.isEmpty ? "untagged" : "#" + tag, tasks: sorted.map { ($0.0, project: $0.1) })
        }
    }

    /// Items made before modes became tags: move each item's mode into its notes as a #tag and clear it. Saves if
    /// anything changed. Safe to run at every launch.
    func migrateModesToTags() {
        let d = FetchDescriptor<Node>(predicate: #Predicate { $0.modeRaw != "" })
        guard let old = try? ctx.fetch(d), !old.isEmpty else { return }
        for n in old {
            let tag = "#" + n.modeRaw
            if !n.tags.contains(n.modeRaw) { n.notes = n.notes.isEmpty ? tag : n.notes + "\n" + tag }
            n.modeRaw = ""
        }
        save()
    }

    /// Done items that have a due date are removed `days` after they were last changed (when they were checked off,
    /// unless edited since). Only leaf items: an item with children stays. Saves if anything was removed. Run at launch.
    @discardableResult
    func pruneDoneDated(olderThan days: Int = 7, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let done = TaskState.done.rawValue
        let d = FetchDescriptor<Node>(predicate: #Predicate { $0.stateRaw == done && $0.due != nil && $0.parentID != nil })
        let old = ((try? ctx.fetch(d)) ?? []).filter { $0.updatedAt < cutoff && children(of: $0.id).isEmpty }
        for n in old { delete(n, actor: .harness) }
        if !old.isEmpty { save() }
        return old.count
    }

    func save() { try? ctx.save() }
}

enum HistoryAction { static let delete = "delete"; static let restore = "restore" }

enum HistoryChange: String, CaseIterable, Hashable { case added, deleted, renamed, completed, moved, edited }

/// One line of History: an item of the outline (or one deleted in the period) and what happened to it.
struct HistoryRow: Identifiable, Equatable {
    let id: UUID
    var depth: Int
    let title: String
    /// Its text before it was renamed in the period (nil: not renamed).
    let oldTitle: String?
    let changes: Set<HistoryChange>
    /// When it last changed in the period.
    let when: Date?
    let done: Bool
    let deleted: Bool
    /// Where it sits (a deleted item: where it was): the item it is under, and its place among that item's children.
    var parentID: UUID? = nil
    var position: Int = 0

    /// "3 added · 1 deleted · 2 completed", or "No changes".
    static func summary(_ rows: [HistoryRow]) -> String {
        let parts = HistoryChange.allCases.compactMap { c -> String? in
            let n = rows.filter { $0.changes.contains(c) }.count
            return n == 0 ? nil : "\(n) \(c.rawValue)"
        }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
    }
}

/// How far back History looks.
enum HistoryPeriod: String, CaseIterable, Identifiable {
    case today, week, month
    var id: String { rawValue }
    var label: String { switch self { case .today: "Today"; case .week: "7 days"; case .month: "30 days" } }
    func start(now: Date = Date()) -> Date {
        switch self {
        case .today: Calendar.current.startOfDay(for: now)
        case .week: now.addingTimeInterval(-7 * 86400)
        case .month: now.addingTimeInterval(-30 * 86400)
        }
    }
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
