import Foundation
import SwiftData
import CoreTransferable
import UniformTypeIdentifiers

/// The whole outline as one JSON file: "Save outline…" writes it, "Open outline…" reads one back in place of the
/// outline on screen. Unlike the text and CSV exports it loses nothing an item holds: status, holder, dates, notes,
/// AI results, dependencies, photos, web links and links between items all come back, under the same ids.
/// Not in the file: History, the Inbox, and calendar events (those are made again for the dated items).
struct OutlineFile: Codable, Equatable, Sendable {
    static let formatName = "schrodinger-outline"
    static let currentVersion = 1

    var format = OutlineFile.formatName
    var version = OutlineFile.currentVersion
    var savedAt = Date()
    /// In outline order: an item comes before the items under it, siblings in the order they are shown.
    var items: [Item] = []
    var attachments: [Extra] = []

    /// One item. Only `title` has to be there, so a file written by hand (or by another tool) can be short.
    struct Item: Codable, Equatable, Sendable {
        var id = UUID()
        var parentID: UUID? = nil
        var title = ""
        var notes = ""
        var state = TaskState.unset.rawValue
        /// Nil: whatever a new item gets.
        var assignee: String? = nil
        var aiStatus = AIStatus.pending.rawValue
        var due: Date? = nil
        var collapsed = false
        var deps: [UUID] = []
        var artifact: String? = nil
        var acceptanceNote = ""
        var goal = ""
        var successCriteria = ""
        var constraints = ""
        var projectStatus = ProjectStatus.active.rawValue
        var calendarIDs: [String] = []
        var createdAt = Date()
        var updatedAt = Date()
    }

    /// A photo or web link on an item, or a link between two items (see `Attachment`).
    struct Extra: Codable, Equatable, Sendable {
        var id = UUID()
        var itemID = UUID()
        var kind = Attachment.Kind.link.rawValue
        var url = ""
        var data: Data? = nil
        var createdAt = Date()
    }

    enum Failure: LocalizedError {
        case notAnOutline, newer
        var errorDescription: String? {
            switch self {
            case .notAnOutline: "This file is not a Schrodinger outline."
            case .newer: "This outline was saved by a newer version of Schrodinger. Update the app to open it."
            }
        }
    }

    // MARK: To and from a file

    func data() throws -> Data {
        let e = JSONEncoder()
        // Dates are written the way Date stores them (seconds from its reference date), so they come back exactly;
        // converted to another epoch they return a hair off.
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    static func read(_ data: Data) throws -> OutlineFile {
        let d = JSONDecoder()
        do { return try d.decode(OutlineFile.self, from: data) }
        catch let f as Failure { throw f }
        catch { throw Failure.notAnOutline }
    }

    static func read(_ url: URL) throws -> OutlineFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try read(Data(contentsOf: url))
    }

    /// What the save panel suggests: "Schrodinger outline 2026-11-24".
    static var defaultFilename: String { "Schrodinger outline " + Date().dayString }

    // MARK: To and from the store

    /// Everything in the outline, as it is now.
    @MainActor
    static func snapshot(_ store: Store) -> OutlineFile {
        let kids = Dictionary(grouping: store.allNodes(), by: \.parentID)   // siblings stay in shown order
        var file = OutlineFile()
        func walk(_ parent: UUID?) {
            for n in kids[parent] ?? [] {
                file.items.append(Item(id: n.id, parentID: n.parentID, title: n.title, notes: n.notes, state: n.stateRaw,
                                       assignee: n.assigneeRaw, aiStatus: n.aiStatusRaw, due: n.due, collapsed: n.collapsed,
                                       deps: n.deps, artifact: n.artifact, acceptanceNote: n.acceptanceNote, goal: n.goal,
                                       successCriteria: n.successCriteria, constraints: n.constraints,
                                       projectStatus: n.projectStatusRaw, calendarIDs: n.calendarIDs,
                                       createdAt: n.createdAt, updatedAt: n.updatedAt))
                walk(n.id)
            }
        }
        walk(nil)
        let ids = Set(file.items.map(\.id))
        let all = (try? store.ctx.fetch(FetchDescriptor<Attachment>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        file.attachments = all.filter { ids.contains($0.nodeID) }.map {
            Extra(id: $0.id, itemID: $0.nodeID, kind: $0.kindRaw, url: $0.urlString, data: $0.data, createdAt: $0.createdAt)
        }
        return file
    }

    /// Puts this outline in place of the one in the store: every current item goes (with its photos, links,
    /// calendar events, History and Inbox entries), then the file's items come in. Saved views and settings stay.
    /// Returns how many items came in. Saves.
    @MainActor @discardableResult
    func load(into store: Store) -> Int {
        let ctx = store.ctx
        let old = store.allNodes()
        let events = old.map(\.calendarEventID).filter { !$0.isEmpty }
        if !events.isEmpty { Task { await CalendarService.shared.remove(eventIDs: events) } }
        for n in old { ctx.delete(n) }
        for a in (try? ctx.fetch(FetchDescriptor<Attachment>())) ?? [] { ctx.delete(a) }
        for a in (try? ctx.fetch(FetchDescriptor<ActivityEntry>())) ?? [] { ctx.delete(a) }
        for p in (try? ctx.fetch(FetchDescriptor<Proposal>())) ?? [] { ctx.delete(p) }

        // An item goes under its parent only if the parent came earlier in the file; otherwise it is top-level.
        // (That also keeps a damaged file from making a loop.) Siblings keep the file's order.
        let known = Set(items.map(\.id))
        var placed: Set<UUID> = []
        var next: [UUID?: Int] = [:]
        for it in items where !placed.contains(it.id) {
            let parent = it.parentID.flatMap { placed.contains($0) ? $0 : nil }
            let n = Node(title: it.title, parentID: parent, due: it.due, position: next[parent, default: 0])
            next[parent, default: 0] += 1
            n.id = it.id
            n.notes = it.notes
            n.state = TaskState(rawValue: it.state) ?? .unset
            if parent != nil, let a = it.assignee.flatMap(Assignee.init(rawValue:)) { n.assignee = a }
            n.aiStatus = AIStatus(rawValue: it.aiStatus) ?? .pending
            n.collapsed = it.collapsed
            n.deps = it.deps.filter { known.contains($0) && $0 != it.id }
            n.artifact = it.artifact
            n.acceptanceNote = it.acceptanceNote
            n.goal = it.goal
            n.successCriteria = it.successCriteria
            n.constraints = it.constraints
            n.projectStatus = ProjectStatus(rawValue: it.projectStatus) ?? .active
            n.calendarIDs = it.calendarIDs
            n.createdAt = it.createdAt
            n.updatedAt = it.updatedAt
            n.lastActivityAt = it.updatedAt
            ctx.insert(n)
            placed.insert(it.id)
        }
        for x in attachments where placed.contains(x.itemID) {
            guard let kind = Attachment.Kind(rawValue: x.kind) else { continue }
            // A link between two items needs both of them.
            if kind == .item, !(UUID(uuidString: x.url).map { placed.contains($0) } ?? false) { continue }
            let a = Attachment(nodeID: x.itemID, kind: kind, urlString: x.url, data: x.data)
            a.id = x.id
            a.createdAt = x.createdAt
            ctx.insert(a)
        }
        store.save()
        return placed.count
    }
}

// Reading is lenient (in an extension, so the memberwise initializers above stay): a missing field takes its default.
extension OutlineFile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decodeIfPresent(String.self, forKey: .format) == OutlineFile.formatName else { throw Failure.notAnOutline }
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= OutlineFile.currentVersion else { throw Failure.newer }
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        attachments = try c.decodeIfPresent([Extra].self, forKey: .attachments) ?? []
    }
}

extension OutlineFile.Item {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? TaskState.unset.rawValue
        assignee = try c.decodeIfPresent(String.self, forKey: .assignee)
        aiStatus = try c.decodeIfPresent(String.self, forKey: .aiStatus) ?? AIStatus.pending.rawValue
        due = try c.decodeIfPresent(Date.self, forKey: .due)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        deps = try c.decodeIfPresent([UUID].self, forKey: .deps) ?? []
        artifact = try c.decodeIfPresent(String.self, forKey: .artifact)
        acceptanceNote = try c.decodeIfPresent(String.self, forKey: .acceptanceNote) ?? ""
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? ""
        successCriteria = try c.decodeIfPresent(String.self, forKey: .successCriteria) ?? ""
        constraints = try c.decodeIfPresent(String.self, forKey: .constraints) ?? ""
        projectStatus = try c.decodeIfPresent(String.self, forKey: .projectStatus) ?? ProjectStatus.active.rawValue
        calendarIDs = try c.decodeIfPresent([String].self, forKey: .calendarIDs) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// An outline file, for the save panel.
struct OutlineFileExport: Transferable {
    var data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
    }
}
