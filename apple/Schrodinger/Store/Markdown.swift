import Foundation

/// One block of a Markdown text, in reading order. Inline marks (bold, links, code spans…) stay in the text and
/// are read by `Markdown.inline` when the block is drawn.
enum MarkdownBlock: Equatable, Sendable {
    enum Marker: Equatable, Sendable { case bullet, number(String), task(done: Bool) }
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(depth: Int, marker: Marker, text: String)
    case quote(String)
    case code(String)
    case rule
    case table(header: [String], rows: [[String]])
}

/// Reads the Markdown the AI writes its results in: headings, paragraphs, lists (nested, numbered, check boxes),
/// quotes, fenced code, rules and tables. Anything it does not know is kept as a paragraph, so no text is lost.
enum Markdown {
    static func blocks(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [MarkdownBlock] = []
        var para: [String] = []
        var indents: [Int] = []      // the indents of the list levels open now
        var open = false             // the last block can still take another line
        var i = 0

        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }

        while i < lines.count {
            let raw = lines[i]
            i += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = Self.indent(of: raw)

            if let fence = Self.fence(line) {
                flush()
                var body: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { body.append(lines[i]); i += 1 }
                i += 1   // the closing fence
                out.append(.code(body.joined(separator: "\n")))
                indents = []; open = false
                continue
            }
            if line.isEmpty { flush(); open = false; continue }
            if let h = Self.heading(line) {
                flush(); out.append(h); indents = []; open = false
                continue
            }
            if line.contains("|"), i < lines.count, Self.isTableRule(lines[i]) {
                flush()
                let header = Self.cells(line)
                i += 1
                var rows: [[String]] = []
                while i < lines.count {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    if r.isEmpty || !r.contains("|") { break }
                    rows.append(Self.cells(r)); i += 1
                }
                out.append(.table(header: header, rows: rows))
                indents = []; open = false
                continue
            }
            // A line of = under a paragraph makes that paragraph a heading.
            if !para.isEmpty, line.count >= 2, line.allSatisfy({ $0 == "=" }) {
                let text = para.joined(separator: " ")
                para = []
                out.append(.heading(level: 1, text: text)); indents = []; open = false
                continue
            }
            if Self.isRule(line) {
                flush(); out.append(.rule); indents = []; open = false
                continue
            }
            if line.hasPrefix(">") {
                flush()
                var text = String(line.dropFirst())
                if text.hasPrefix(" ") { text.removeFirst() }
                if open, case .quote(let before)? = out.last { out[out.count - 1] = .quote(before + "\n" + text) } else { out.append(.quote(text)) }
                indents = []; open = true
                continue
            }
            if let item = Self.listItem(line) {
                flush()
                while let last = indents.last, last > indent { indents.removeLast() }
                if indents.last != indent { indents.append(indent) }
                out.append(.listItem(depth: indents.count - 1, marker: item.marker, text: item.text))
                open = true
                continue
            }
            // An indented line right under a list item goes on with that item.
            if open, indent > 0, para.isEmpty, case .listItem(let depth, let marker, let text)? = out.last {
                out[out.count - 1] = .listItem(depth: depth, marker: marker, text: text + " " + line)
                continue
            }
            para.append(line); indents = []; open = false
        }
        flush()
        return out
    }

    /// Bold, italics, code spans, strikethrough and links in one block's text. Line breaks are kept.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static func indent(of raw: String) -> Int {
        var n = 0
        for c in raw {
            if c == " " { n += 1 } else if c == "\t" { n += 4 } else { break }
        }
        return n
    }

    private static func fence(_ line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        if let closing = text.range(of: " #+$", options: .regularExpression) { text.removeSubrange(closing) }
        return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let s = line.filter { $0 != " " }
        guard s.count >= 3, let c = s.first, c == "-" || c == "*" || c == "_" else { return false }
        return s.allSatisfy { $0 == c }
    }

    private static func listItem(_ line: String) -> (marker: MarkdownBlock.Marker, text: String)? {
        if let first = line.first, first == "-" || first == "*" || first == "+", line.dropFirst().first == " " {
            let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[ ] ") { return (.task(done: false), String(text.dropFirst(4))) }
            if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { return (.task(done: true), String(text.dropFirst(4))) }
            return (.bullet, text)
        }
        let digits = line.prefix(while: { $0 >= "0" && $0 <= "9" })
        guard (1...9).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return (.number(String(digits)), rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    private static func isTableRule(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        return s.contains("-") && s.contains("|") && s.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " }
    }

    private static func cells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
