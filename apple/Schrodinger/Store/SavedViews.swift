import Foundation
import SwiftData

/// A view of the outline saved under a name, to return to with one tap: the search text, the filter and tag
/// chosen in the header menu, and the item the outline is zoomed into (the focus). Any of them may be unset.
///
/// Stored as a `WorkspaceFile` (one per view, JSON in `content`) on a reserved shelf rather than as a model of its
/// own, so the iCloud schema needs no new record type; with iCloud sync on, saved views sync with everything else.
struct SavedView: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var search: String = ""
    /// `OutlineView.Filter` raw value ("all" = no filter).
    var filter: String = "all"
    var tag: String? = nil
    /// The zoomed item, or nil for the whole outline.
    var zoomID: UUID? = nil
    var position: Int = 0

    /// The `projectID` every saved view's file carries. No item has this id, so no agent or project sees these files.
    static let shelfID = UUID(uuidString: "5C4D1A6E-5A7E-4D00-8000-0000F0C05ED0")!
    static let pathPrefix = "views/"
    var path: String { Self.pathPrefix + id.uuidString + ".json" }

    init(id: UUID = UUID(), name: String, search: String = "", filter: String = "all", tag: String? = nil, zoomID: UUID? = nil, position: Int = 0) {
        self.id = id; self.name = name; self.search = search; self.filter = filter; self.tag = tag; self.zoomID = zoomID; self.position = position
    }

    private enum CodingKeys: String, CodingKey { case id, name, search, filter, tag, zoomID, position }
    /// Missing keys take their defaults, so a view saved by another version of the app still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        search = try c.decodeIfPresent(String.self, forKey: .search) ?? ""
        filter = try c.decodeIfPresent(String.self, forKey: .filter) ?? "all"
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        zoomID = try c.decodeIfPresent(UUID.self, forKey: .zoomID)
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
    }

    init?(json: String) {
        guard let v = try? JSONDecoder().decode(SavedView.self, from: Data(json.utf8)) else { return nil }
        self = v
    }
    var json: String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Search text as the outline reads it: lowercase words (a lone "#" is not a term).
    static func terms(_ search: String) -> [String] {
        search.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0 != "#" }
    }
    /// Nothing to save: no search, no filter, no tag, not zoomed.
    static func isPlain(search: String, filter: String, tag: String?, zoomID: UUID?) -> Bool {
        terms(search).isEmpty && filter == "all" && tag == nil && zoomID == nil
    }
    /// The outline is showing exactly this view.
    func matches(search: String, filter: String, tag: String?, zoomID: UUID?) -> Bool {
        Self.terms(self.search) == Self.terms(search) && self.filter == filter && self.tag == tag && self.zoomID == zoomID
    }
    /// A name to offer when saving: what the view shows, broadest part first.
    static func suggestedName(search: String, filterLabel: String?, tag: String?, zoomTitle: String?) -> String {
        var parts: [String] = []
        if let z = zoomTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !z.isEmpty { parts.append(z) }
        if let f = filterLabel, !f.isEmpty { parts.append(f) }
        if let t = tag, !t.isEmpty { parts.append("#" + t) }
        let s = search.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !s.isEmpty { parts.append(s) }
        return parts.joined(separator: " \u{00B7} ")
    }
    /// The saved views among `files`, in their saved order.
    static func all(in files: [WorkspaceFile]) -> [SavedView] {
        files.filter { $0.projectID == shelfID && $0.path.hasPrefix(pathPrefix) }
            .compactMap { SavedView(json: $0.content) }
            .sorted { ($0.position, $0.name.lowercased(), $0.id.uuidString) < ($1.position, $1.name.lowercased(), $1.id.uuidString) }
    }
}

extension Store {
    // MARK: - Saved views (named searches / filters / zooms)
    func savedViews() -> [SavedView] { SavedView.all(in: files(for: SavedView.shelfID)) }

    /// Saves the view under `name`. A view already saved under that name (any letter case) is replaced and keeps its
    /// place in the list; otherwise the new one goes last. Returns nil when the name is blank.
    @discardableResult
    func saveView(name: String, search: String, filter: String, tag: String?, zoomID: UUID?) -> SavedView? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let existing = savedViews()
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var v = SavedView(name: name, search: search, filter: filter, tag: tag, zoomID: zoomID, position: (existing.map(\.position).max() ?? -1) + 1)
        if let old = existing.first(where: { $0.name.lowercased() == name.lowercased() }) { v.id = old.id; v.position = old.position }
        writeFile(SavedView.shelfID, v.path, v.json)
        return v
    }

    /// Renames a saved view. Refused (false) when the name is blank or another view already has it.
    @discardableResult
    func renameView(_ id: UUID, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let views = savedViews()
        guard !name.isEmpty, var v = views.first(where: { $0.id == id }),
              !views.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) else { return false }
        v.name = name
        writeFile(SavedView.shelfID, v.path, v.json)
        return true
    }

    func deleteView(_ id: UUID) {
        // Every file holding this view (a sync could in principle leave more than one).
        for f in files(for: SavedView.shelfID) where SavedView(json: f.content)?.id == id { ctx.delete(f) }
    }
}
