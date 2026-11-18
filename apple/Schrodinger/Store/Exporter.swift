import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// Writes items out as text (for Notes, or anywhere text goes) or as a CSV file. Both read back in with `Importer`.
enum Exporter {
    /// An outline as text: the item's title, then its children as an indented list (`- [x]` for done items, two
    /// spaces per level). Notes are lines starting with `> ` under their item. With no item: every top-level item.
    @MainActor
    static func text(_ rootID: UUID?, store: Store) -> String {
        var lines: [String] = []
        func walk(_ parent: UUID, depth: Int) {
            for n in store.children(of: parent) {
                let pad = String(repeating: "  ", count: depth)
                lines.append(pad + (n.state == .done ? "- [x] " : "- ") + n.title + dueSuffix(n.due))
                for l in n.notes.split(separator: "\n", omittingEmptySubsequences: true) { lines.append(pad + "  > " + l) }
                walk(n.id, depth: depth + 1)
            }
        }
        let tops = rootID.flatMap { store.node($0) }.map { [$0] } ?? store.children(of: nil)
        for (i, top) in tops.enumerated() {
            if i > 0 { lines.append("") }
            lines.append(rootID == nil ? "# " + top.title : top.title)
            for l in top.notes.split(separator: "\n", omittingEmptySubsequences: true) { lines.append("> " + l) }
            walk(top.id, depth: 0)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Rows: Title, Notes, Due, Done, Depth (0 = the exported item itself, or a top-level item).
    @MainActor
    static func csv(_ rootID: UUID?, store: Store) -> String {
        var rows = [["Title", "Notes", "Due", "Done", "Depth"]]
        func add(_ n: Node, _ depth: Int) {
            rows.append([n.title, n.notes, n.due.map(dateText) ?? "", n.state == .done ? "yes" : "", String(depth)])
            for c in store.children(of: n.id) { add(c, depth + 1) }
        }
        for top in rootID.flatMap({ store.node($0) }).map({ [$0] }) ?? store.children(of: nil) { add(top, 0) }
        return rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private static func field(_ s: String) -> String {
        s.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
    private static func dateText(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = d.hasTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return f.string(from: d)
    }
    /// A due date at the end of a text line: ` (due 2026-12-01)`.
    private static func dueSuffix(_ d: Date?) -> String { d.map { " (due \(dateText($0)))" } ?? "" }
    static func parseDueSuffix(_ title: String) -> (title: String, due: Date?) {
        guard title.hasSuffix(")"), let r = title.range(of: " (due ", options: .backwards) else { return (title, nil) }
        let inner = String(title[r.upperBound...].dropLast())
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: inner) { return (String(title[..<r.lowerBound]), d) }
        }
        return (title, nil)
    }
}

/// An outline as text, made when it is shared (not each time the menu holding the Share button is drawn).
struct OutlineText: Transferable {
    var rootID: UUID?
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { (e: OutlineText) in await MainActor.run { Exporter.text(e.rootID, store: Store(AppData.container.mainContext)) } }
    }
}

/// A CSV export, for the file exporter.
struct CSVExport: Transferable {
    var text: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data($0.text.utf8) }
    }
}
