import Foundation
import SwiftData

/// Weaving: an item and everything under it, made into one continuous piece of writing. The item is the piece; the
/// items under it are its threads (their titles, notes, results and links are the material). It happens only when
/// the owner asks (the Weave button on an item that has children). The piece is put on the item as its result, so it
/// is read, shared, commented on and undone like any other result. The item's status and holder are not changed.
/// Passages in the piece link back to the items they came from (`item:` links, see `WeaveLinks`).
@MainActor
enum WeaveBrief {
    /// The glyph for weaving: crossed threads.
    static let symbol = "line.3.crossed.swirl.circle"
    /// Characters of one thread's result that go to the model.
    static let perThread = 12_000

    static func make(nodeID: UUID, container: ModelContainer, budget: Int = 120_000) -> HandoffBrief.Text? {
        let s = Store(container.mainContext)
        guard let root = s.node(nodeID), !root.isDeleted else { return nil }
        let threads = material(root: root, store: s, budget: budget)
        guard threads.count > 0 else { return nil }
        return HandoffBrief.Text(system: system(project: s.project(of: root)), prompt: prompt(root: root, threads: threads.text, store: s))
    }

    static func system(project: Node) -> String {
        """
        You weave the items under one heading of the owner's outline into a single coherent long-form piece of writing. The heading is the piece. The items under it are its threads, given in outline order: a thread's title is a point or a section topic, and its notes and result are the material.
        Context, from the top of the outline: "\(project.title)"\(project.goal.isEmpty ? "" : "\nIts goal: " + project.goal)\(project.constraints.isEmpty ? "" : "\nConstraints: " + project.constraints)

        How to weave:
        - Use everything of substance in the threads. Keep their order unless the argument clearly needs another. State no fact that is not in the threads. Where a thread is only a title, write what the title and its neighbours support and no more.
        - Write continuous prose with transitions between the parts. It must read as one piece by one writer, not as the items listed one after another. Start with a # title. Use ## headings only where the piece is long enough to need them.
        - Follow what the owner's notes on the piece say about audience, voice, length or form. Without them: plain, direct prose, as long as the material supports.
        - Leave out to-do bookkeeping (statuses, dates, who holds an item) unless it is the subject.
        - Link each passage to its source. Every thread is given with an id in square brackets. At the end of each paragraph, add one link for each thread the paragraph draws on, written exactly as [↗](item:ID) with that thread's id. Never invent an id, and never link a thread you did not use there.
        - Return only the piece, in Markdown. No preamble, no closing remarks, no notes about what you did.
        """
    }

    static func prompt(root: Node, threads: String, store s: Store, now: Date = Date()) -> String {
        var lines = ["Today is \(now.dayString)."]
        lines.append("The piece: \"\(root.title)\"")
        var path: [String] = []
        var cur = root
        while let pid = cur.parentID, let up = s.node(pid), path.count < 12 { path.insert(up.title, at: 0); cur = up }
        if !path.isEmpty { lines.append("Where it sits in the outline: " + path.joined(separator: " > ")) }
        // A top-level item's notes are kept as its goal.
        let notes = (root.isProject ? root.goal : root.notes).trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { lines.append("The owner's notes on the piece (follow any instructions in them):\n\(notes)") }
        lines.append("The threads. Each begins with a line: number, [id], title. Deeper numbers are under shallower ones.\n\n\(threads)")
        if let a = root.artifact, !a.isEmpty {
            lines.append("The text now on the piece's item (an earlier weave, to improve on; ignore the links in it):\n\(WeaveLinks.withoutThreadList(a).prefix(20_000))")
        }
        if !root.acceptanceNote.isEmpty { lines.append("The owner's comments on the earlier text (address these):\n\(root.acceptanceNote)") }
        return lines.joined(separator: "\n\n")
    }

    /// Everything under `root`, in outline order, as text for the model: each item with its number, id and title, then
    /// its notes, its result and its links. Stops at `budget` characters and says how many items were left out.
    static func material(root: Node, store s: Store, budget: Int) -> (text: String, count: Int) {
        var out: [String] = []
        var used = 0, count = 0, skipped = 0
        func walk(_ parent: Node, _ prefix: String) {
            for (i, n) in s.children(of: parent.id).enumerated() {
                let number = prefix.isEmpty ? "\(i + 1)" : "\(prefix).\(i + 1)"
                var part = ["\(number) [\(WeaveLinks.ref(n.id))] \(n.title.isEmpty ? "(untitled)" : n.title)"]
                let notes = n.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !notes.isEmpty { part.append("Notes: \(notes)") }
                if let a = n.artifact?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
                    part.append("Result:\n\(WeaveLinks.withoutThreadList(a).prefix(perThread))")
                }
                let links = s.attachments(for: n.id).filter { $0.kind == .link }.map(\.urlString)
                if !links.isEmpty { part.append("Links: " + links.joined(separator: " ")) }
                let text = part.joined(separator: "\n")
                if used + text.count > budget && count > 0 { skipped += 1 + s.descendants(of: n.id).count; continue }
                used += text.count + 2
                count += 1
                out.append(text)
                walk(n, number)
            }
        }
        walk(root, "")
        if skipped > 0 { out.append("(\(skipped) more \(skipped == 1 ? "item was" : "items were") left out for length.)") }
        return (out.joined(separator: "\n\n"), count)
    }
}

/// The links in a woven piece that lead back to the items it was made from. A link's address is `item:` followed by
/// the first eight characters of the item's id, so it is short enough for a model to copy exactly. Tapping one in
/// the app opens that item in the outline (see ContentView). Outside the app the links lead nowhere.
enum WeaveLinks {
    static let scheme = "item"
    static let listHeading = "## Threads"

    /// The id an item goes by in a piece.
    static func ref(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }
    static func address(_ id: UUID) -> String { "\(scheme):\(ref(id))" }

    /// The id text in an `item:` address, or nil for any other address.
    static func ref(in url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let text = String(url.absoluteString.dropFirst(scheme.count + 1)).uppercased().filter { $0.isHexDigit }
        return text.count >= 8 ? text : nil
    }
    /// The item an `item:` address leads to, among `ids`.
    static func target(of url: URL, among ids: [UUID]) -> UUID? {
        guard let r = ref(in: url) else { return nil }
        return ids.first { $0.uuidString.hasPrefix(r) }
    }

    /// What a model returned, as the piece: an outer code fence is removed, and so is any list of threads it wrote
    /// itself (the app adds the real one).
    static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```"), t.hasSuffix("```"), let firstBreak = t.firstIndex(of: "\n") {
            let inner = t[t.index(after: firstBreak)...].dropLast(3)
            if !inner.contains("```") { t = inner.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return withoutThreadList(t)
    }

    /// The piece without the list of threads at its end.
    static func withoutThreadList(_ text: String) -> String {
        guard let r = text.range(of: "\n" + listHeading + "\n", options: .backwards) else { return text }
        return String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The list of threads at a piece's end, from its heading on (nil when it has none).
    static func threadListPart(of text: String) -> String? {
        guard let r = text.range(of: "\n" + listHeading + "\n", options: .backwards) else { return nil }
        return String(text[r.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes links to items that are not among `valid` (an id the model got wrong), keeping the text around them.
    static func pruned(_ text: String, valid: Set<String>) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\s?\\[([^\\]\\n]*)\\]\\(item:([0-9A-Fa-f-]+)\\)") else { return text }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let id = String(ns.substring(with: m.range(at: 2)).uppercased().filter { $0.isHexDigit }.prefix(8))
            if valid.contains(id) { continue }
            let label = ns.substring(with: m.range(at: 1))
            // A mark that is only an arrow goes entirely; a link made of words keeps its words.
            let keep = label.contains(where: { $0.isLetter || $0.isNumber }) ? " " + label : ""
            out = (out as NSString).replacingCharacters(in: m.range, with: keep)
        }
        return out
    }

    /// The list of threads that ends a piece: every item it was woven from, in outline order, each a link to its item.
    static func threadList(_ threads: [(number: String, node: Node)]) -> String {
        guard !threads.isEmpty else { return "" }
        let rows = threads.map { t in
            let depth = t.number.filter { $0 == "." }.count
            let title = (t.node.title.isEmpty ? "Untitled" : t.node.title)
                .replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "\n", with: " ")
            return String(repeating: "  ", count: depth) + "- [\(title)](\(address(t.node.id)))"
        }
        return listHeading + "\n" + rows.joined(separator: "\n")
    }
}

extension Store {
    /// Everything under an item, depth first in outline order, each with its outline number ("2.1").
    func numberedDescendants(of id: UUID) -> [(number: String, node: Node)] {
        var out: [(number: String, node: Node)] = []
        func walk(_ parent: UUID, _ prefix: String) {
            for (i, n) in children(of: parent).enumerated() {
                let number = prefix.isEmpty ? "\(i + 1)" : "\(prefix).\(i + 1)"
                out.append((number, n))
                walk(n.id, number)
            }
        }
        walk(id, "")
        return out
    }

    /// Puts a woven piece on its item as the item's result: the model's text with links to unknown items removed,
    /// then the list of the items it was woven from, each linked. Recorded in the item's activity, so the text that
    /// was there before can be brought back with undo. The item's status and holder stay as they are.
    /// Returns the piece as stored (nil when the model returned nothing).
    @discardableResult
    func applyWeave(_ text: String, to n: Node) -> String? {
        let threads = numberedDescendants(of: n.id)
        let body = WeaveLinks.pruned(WeaveLinks.clean(text), valid: Set(threads.map { WeaveLinks.ref($0.node.id) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let list = WeaveLinks.threadList(threads)
        let piece = list.isEmpty ? body : body + "\n\n" + list
        update(n, actor: .ai, detail: "woven from \(threads.count) \(threads.count == 1 ? "item" : "items")") { $0.artifact = piece }
        return piece
    }

    /// The owner's own edit of a result's text (typed in the result viewer). A woven piece keeps its list of
    /// threads, which is not part of the text being edited. Recorded in the item's activity, so it can be undone.
    func saveEditedResult(_ n: Node, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let list = n.artifact.flatMap { WeaveLinks.threadListPart(of: $0) }
        let piece = list.map { body + "\n\n" + $0 } ?? body
        guard piece != n.artifact else { return }
        update(n, detail: "result edited") { $0.artifact = piece }
    }

    /// The owner's comments on a woven piece: kept on the item, for the next weave to address. Nothing else changes.
    func noteOnWeave(_ n: Node, note: String) {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        update(n, detail: "edits requested: \(note)") { x in
            x.acceptanceNote = [x.acceptanceNote, "[edits \(Date().dayString)] \(note)"].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }
}
