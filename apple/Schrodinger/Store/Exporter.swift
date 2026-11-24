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

extension UTType {
    /// Markdown, which is what the AI writes its results in. Falls back to plain text where the system has no such type.
    static let resultMarkdown = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
}

/// An AI result, for other apps: a Markdown file named after its item (Files, Mail, an editor, AirDrop…), or its
/// text for apps that take text (Notes, Messages…). The receiving app picks the form it can use.
struct ResultFile: Transferable {
    var title: String
    var markdown: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .resultMarkdown) { (r: ResultFile) in SentTransferredFile(try r.write()) }
        ProxyRepresentation { (r: ResultFile) in r.markdown }
    }

    /// A file name any file system takes: no path separators or line breaks, not too long, never empty.
    static func filename(for title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:\0").union(.newlines).union(.controlCharacters)
        var name = title.components(separatedBy: bad).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "Result" : name) + ".md"
    }

    /// Writes the result to a temporary file and returns where. Each call gets its own folder, so the name stays clean.
    func write() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Results", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Self.filename(for: title))
        try Data(markdown.utf8).write(to: url, options: .atomic)
        return url
    }
}
