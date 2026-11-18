import Foundation
import UniformTypeIdentifiers

/// Turns a CSV file, or text (a .txt / .md file, or a note from Apple Notes), into items. Everything imported goes
/// under one new item named after the file or the note, so an import is easy to find, move or delete.
enum Importer {
    /// What the file picker offers: CSV, plain text, Markdown.
    static let fileTypes: [UTType] = [.commaSeparatedText, .plainText, .text] + [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }

    struct Entry: Equatable {
        /// Nesting under the import's top item: 0 = its direct child.
        var depth: Int
        var title: String
        var notes = ""
        var done = false
        var due: Date? = nil
    }

    // MARK: Text (Apple Notes, Markdown, plain text)

    /// Headings (`#`) and plain lines become items; list lines (`-`, `*`, `•`, `1.`, `[ ]`…) nest under the line above
    /// them, deeper as they are indented. A long paragraph is kept as the notes of the item before it.
    static func parse(text: String) -> [Entry] { parseText(text).entries }

    /// `parse(text:)`, plus the `> ` notes that came before any item (they belong to the import's top item).
    static func parseText(_ text: String) -> (entries: [Entry], lead: String) {
        var out: [Entry] = []
        var headingDepth = -1          // depth of the latest heading; plain lines go one below it
        var base = -1                  // depth of the latest heading or plain line; list lines go below it
        var indents: [Int] = []        // indents of the open list levels in the current list
        var leadNotes = ""
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = normalizeBullet(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // `> text`: notes of the item above (how exported text carries notes).
            if trimmed.hasPrefix(">") {
                let note = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if out.isEmpty { leadNotes += (leadNotes.isEmpty ? "" : "\n") + note }
                else { out[out.count - 1].notes += (out[out.count - 1].notes.isEmpty ? "" : "\n") + note }
                continue
            }
            if let h = heading(trimmed) {
                let d = h.level - 1
                out.append(Entry(depth: d, title: h.title)); headingDepth = d; base = d; indents = []
            } else if let it = ListText.item(line) {
                while let last = indents.last, last >= it.indent { indents.removeLast() }
                out.append(Entry(depth: base + 1 + indents.count, title: it.title, done: it.done))
                indents.append(it.indent)
            } else if trimmed.count > 120, !out.isEmpty {
                out[out.count - 1].notes += (out[out.count - 1].notes.isEmpty ? "" : "\n") + trimmed
            } else {
                let d = headingDepth + 1
                out.append(Entry(depth: d, title: trimmed)); base = d; indents = []
            }
        }
        let entries = normalized(out).map { e in
            var e = e
            let (t, due) = Exporter.parseDueSuffix(e.title)
            if let due { e.title = t; e.due = due }
            return e
        }
        return (entries, leadNotes)
    }

    /// A Markdown heading: `# Title` (level 1) to `###### Title`.
    private static func heading(_ s: String) -> (level: Int, title: String)? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let t = rest.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : (hashes, t)
    }

    /// Bullets that Notes and other apps use but the typing parser doesn't (◦ ▪ ‣ ○ – —) are read as `-`.
    private static func normalizeBullet(_ line: String) -> String {
        let lead = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(lead.count)
        guard let f = rest.first, "◦▪‣○–—·".contains(f), rest.dropFirst().first == " " else { return line }
        return lead + "-" + rest.dropFirst()
    }

    // MARK: CSV

    /// With a header row, columns are found by name: title (or name, task, item), notes (description, details),
    /// due (date, deadline), done (completed, status), and depth (level, indent) or parent (a title from an earlier
    /// row). Without one, the first column is the title and the second the notes.
    static func parse(csv: String) -> [Entry] {
        var rows = csvRows(csv).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !rows.isEmpty else { return [] }
        let header = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        let named = col(["title", "name", "task", "item", "subject"])
        var title = 0, notes: Int? = 1, due: Int?, done: Int?, depth: Int?, parent: Int?
        if let named {
            rows.removeFirst()
            title = named
            notes = col(["notes", "note", "description", "details", "body"])
            due = col(["due", "date", "due date", "deadline"])
            done = col(["done", "completed", "complete", "status", "state"])
            depth = col(["depth", "level", "indent"])
            parent = col(["parent"])
        }
        var out: [Entry] = []
        var depthOfTitle: [String: Int] = [:]
        for r in rows {
            func cell(_ i: Int?) -> String { guard let i, i < r.count else { return "" }; return r[i].trimmingCharacters(in: .whitespacesAndNewlines) }
            let t = cell(title)
            guard !t.isEmpty else { continue }
            var d = Int(cell(depth)) ?? 0
            if let p = depthOfTitle[cell(parent)], !cell(parent).isEmpty { d = p + 1 }
            let doneText = cell(done).lowercased()
            let e = Entry(depth: d, title: t, notes: cell(notes),
                          done: ["true", "yes", "y", "x", "1", "done", "completed", "complete"].contains(doneText),
                          due: date(cell(due)))
            out.append(e)
            depthOfTitle[t] = d
        }
        return normalized(out)
    }

    /// Rows of a CSV file: commas (or semicolons / tabs, whichever the first line uses most), double-quoted fields
    /// with `""` for a quote, and line breaks inside quotes.
    static func csvRows(_ s: String) -> [[String]] {
        let first = s.prefix { $0 != "\n" }
        let sep: Character = [",", ";", "\t"].max { a, b in first.filter { $0 == a }.count < first.filter { $0 == b }.count } ?? ","
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = Array(s.replacingOccurrences(of: "\r\n", with: "\n")).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty { quoted = true }
            else if c == sep { row.append(field); field = "" }
            else if c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    private static func date(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        if let d = try? Date(s, strategy: .iso8601) { return d }
        for f in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "M/d/yyyy", "M/d/yy", "MMM d, yyyy", "d MMM yyyy"] {
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    /// Depths start at 0 and never jump more than one level deeper than the item before.
    private static func normalized(_ entries: [Entry]) -> [Entry] {
        guard let low = entries.map(\.depth).min() else { return [] }
        var out: [Entry] = [], prev = -1
        for var e in entries { e.depth = min(e.depth - low, prev + 1); prev = e.depth; out.append(e) }
        return out
    }

    // MARK: Into the outline

    /// Adds `entries` under a new item titled `title`, placed under `parentID` (nil: a new top-level item). Returns
    /// the new item's id. Saves.
    @MainActor @discardableResult
    static func insert(_ entries: [Entry], title: String, under parentID: UUID?, store: Store) -> UUID {
        let top = store.create(title: title, parentID: parentID)
        var trail: [UUID] = [top.id]   // trail[d] is the latest item at depth d-1 (trail[0] is the top item)
        for e in entries {
            trail = Array(trail.prefix(e.depth + 1))
            let n = store.create(title: e.title, parentID: trail.last, due: e.due)
            if !e.notes.isEmpty || e.done { store.update(n) { if !e.notes.isEmpty { $0.notes = e.notes }; if e.done { $0.state = .done } } }
            trail.append(n.id)
        }
        store.save()
        return top.id
    }

    /// Imports a file's contents. CSV by extension; anything else is read as text.
    @MainActor @discardableResult
    static func importFile(_ url: URL, under parentID: UUID?, store: Store) throws -> UUID {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let raw = try Data(contentsOf: url)
        let text = String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self)
        let name = url.deletingPathExtension().lastPathComponent
        let entries = url.pathExtension.lowercased() == "csv" ? parse(csv: text) : parse(text: text)
        return insert(entries, title: name, under: parentID, store: store)
    }

    /// Imports a note's text: its first line is the new item's title, the rest its children.
    @MainActor @discardableResult
    static func importNote(_ text: String, under parentID: UUID?, store: Store) -> UUID {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let firstIndex = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? 0
        let first = lines.isEmpty ? "" : lines[firstIndex]
        let title = heading(first.trimmingCharacters(in: .whitespaces))?.title ?? ListText.item(first)?.title ?? first.trimmingCharacters(in: .whitespaces)
        let rest = lines.dropFirst(firstIndex + 1).joined(separator: "\n")
        let (entries, leadNotes) = parseText(rest)
        let (t, due) = Exporter.parseDueSuffix(title)
        let id = insert(entries, title: t.isEmpty ? "Imported note" : t, under: parentID, store: store)
        if let top = store.node(id), !leadNotes.isEmpty || due != nil {
            store.update(top) { if !leadNotes.isEmpty { $0.notes = leadNotes }; if let due { $0.due = due } }; store.save()
        }
        return id
    }
}
