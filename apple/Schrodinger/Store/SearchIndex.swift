import Foundation
import SwiftData
#if canImport(CoreSpotlight)
import CoreSpotlight
import UniformTypeIdentifiers
#endif

/// The in-app search index: each item's searchable text, lowercased once, and its tags. The outline's search, its
/// filters and the counts on the filter buttons ask it instead of lowercasing every item's text again for every
/// question. It is rebuilt whenever an item's text changes, or an item is added or removed (`refresh`).
@MainActor final class SearchIndex {
    struct Entry: Equatable, Sendable {
        let text: String
        let tags: Set<String>
        init(title: String, notes: String, goal: String) {
            text = (title + "\n" + notes + "\n" + goal).lowercased()
            tags = Tags.all(in: title, notes, goal)
        }
        init(_ n: Node) { self.init(title: n.title, notes: n.notes, goal: n.goal) }
        /// The item has every term: a word in its text, or (for #tag and @person) among its tags. Terms are lowercase.
        func matches(_ terms: [String]) -> Bool {
            terms.allSatisfy { t in Tags.tag(term: t).map { tags.contains($0) } ?? text.contains(t) }
        }
    }

    private(set) var entries: [UUID: Entry] = [:]
    /// What the index was built from (`signature`): changes exactly when it has to be rebuilt. 0 before the first build.
    private(set) var builtFrom = 0
    /// How many times the index has been built.
    private(set) var builds = 0

    /// Everything a search reads, for every item: differs whenever an item's text changes or an item comes or goes.
    /// Only the same within one run of the app.
    static func signature(_ nodes: [Node]) -> Int {
        var h = Hasher()
        h.combine(nodes.count)
        for n in nodes where !n.isDeleted { h.combine(n.id); h.combine(n.title); h.combine(n.notes); h.combine(n.goal) }
        return h.finalize()
    }

    /// Brings the index up to date with `nodes`. Rebuilds only if something a search reads has changed; returns
    /// whether it did.
    @discardableResult func refresh(_ nodes: [Node]) -> Bool {
        let s = Self.signature(nodes)
        if builds > 0 && s == builtFrom { return false }
        var out: [UUID: Entry] = [:]
        out.reserveCapacity(nodes.count)
        for n in nodes where !n.isDeleted { out[n.id] = Entry(n) }
        entries = out; builtFrom = s; builds += 1
        return true
    }

    /// Whether the item has every term. An item the index does not hold yet is read directly.
    func matches(_ n: Node, terms: [String]) -> Bool {
        if terms.isEmpty { return true }
        return (entries[n.id] ?? Entry(n)).matches(terms)
    }
    /// The item's tags, from the index.
    func tags(_ n: Node) -> Set<String> { entries[n.id]?.tags ?? n.tags }
}

/// The system search index (Spotlight): every item with a title, findable from the system's search on iPhone, iPad
/// and Mac; choosing one opens it in the outline. Kept on the device, like the rest of the data. Brought up to date
/// whenever items change: changed and new items are indexed again, deleted ones are removed.
@MainActor enum SpotlightIndex {
    static let domain = "org.schrodinger.items"
    /// The identifiers in the system index, kept between launches so items deleted while the app was closed (on
    /// another device, say) are removed at the next sync.
    static let indexedKey = "spotlightIndexedIDs"

    struct Doc: Equatable, Sendable {
        let id: UUID
        let title: String
        let notes: String
        let path: String
        let tags: [String]
        let due: Date?
    }
    struct Changes: Equatable { var index: [Doc] = []; var remove: [String] = [] }

    /// What this run of the app has put in the system index, by item. nil until the first sync, which indexes everything.
    private static var indexed: [UUID: Doc]? = nil

    /// Everything a document is made from, for every item: the `.task(id:)` that runs `sync` restarts when it changes.
    static func signature(_ nodes: [Node]) -> Int {
        var h = Hasher()
        h.combine(nodes.count)
        for n in nodes where !n.isDeleted { h.combine(n.id); h.combine(n.parentID); h.combine(n.title); h.combine(n.notes); h.combine(n.goal); h.combine(n.due) }
        return h.finalize()
    }

    /// One document per item that has a title or notes. `path` is the titles of the item's ancestors, outermost first.
    static func docs(_ nodes: [Node]) -> [Doc] {
        let live = nodes.filter { !$0.isDeleted }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return live.compactMap { n in
            let title = n.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = [n.notes, n.goal].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
            if title.isEmpty && notes.isEmpty { return nil }
            var path: [String] = []
            var p = n.parentID, hops = 0
            while let id = p, let a = byID[id], hops < 64 { if !a.title.isEmpty { path.insert(a.title, at: 0) }; p = a.parentID; hops += 1 }
            return Doc(id: n.id, title: title.isEmpty ? "Untitled" : title, notes: notes, path: path.joined(separator: " \u{203A} "),
                       tags: n.tags.sorted(), due: n.due)
        }
    }

    /// What to send to the system index to get from `old` to `new`. `known` are identifiers already in the system
    /// index (from earlier launches). With no `old` (first sync of a run) everything is indexed again.
    static func changes(from old: [UUID: Doc]?, to new: [Doc], known: [String]) -> Changes {
        var c = Changes()
        let ids = Set(new.map(\.id.uuidString))
        if let old { c.index = new.filter { old[$0.id] != $0 } } else { c.index = new }
        c.remove = Set(known).union((old ?? [:]).keys.map(\.uuidString)).subtracting(ids).sorted()
        return c
    }

    /// Brings the system index up to date with the store. Waits a moment first, so a burst of edits (typing a title)
    /// makes one update: the caller's task is cancelled and restarted on every change.
    static func sync(container: ModelContainer) async {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        try? await Task.sleep(for: .seconds(1))
        if Task.isCancelled { return }
        #if canImport(CoreSpotlight)
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let nodes = (try? container.mainContext.fetch(FetchDescriptor<Node>())) ?? []
        let new = docs(nodes)
        let d = UserDefaults.standard
        let c = changes(from: indexed, to: new, known: d.stringArray(forKey: indexedKey) ?? [])
        let index = CSSearchableIndex.default()
        if !c.remove.isEmpty { index.deleteSearchableItems(withIdentifiers: c.remove, completionHandler: nil) }
        if !c.index.isEmpty { index.indexSearchableItems(c.index.map(item), completionHandler: nil) }
        indexed = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        d.set(new.map(\.id.uuidString), forKey: indexedKey)
        #endif
    }

    #if canImport(CoreSpotlight)
    static func item(_ doc: Doc) -> CSSearchableItem {
        let a = CSSearchableItemAttributeSet(contentType: .text)
        a.title = doc.title
        a.contentDescription = [doc.path, doc.notes].filter { !$0.isEmpty }.joined(separator: "\n")
        a.keywords = doc.tags
        a.dueDate = doc.due
        let it = CSSearchableItem(uniqueIdentifier: doc.id.uuidString, domainIdentifier: domain, attributeSet: a)
        it.expirationDate = .distantFuture   // stays until the item is deleted (the default drops it after a month)
        return it
    }

    /// The item a chosen system search result stands for.
    nonisolated static func itemID(from activity: NSUserActivity) -> UUID? {
        (activity.userInfo?[CSSearchableItemActivityIdentifier] as? String).flatMap(UUID.init(uuidString:))
    }
    #endif
}
