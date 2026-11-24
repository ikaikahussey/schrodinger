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
/// quotes, fenced code, rules and tables. HTML and XML tags in the text are read too (see `normalizeHTML`). Anything
/// it does not know is kept as a paragraph, so no text is lost.
enum Markdown {
    static func blocks(_ source: String) -> [MarkdownBlock] {
        let lines = normalizeHTML(source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
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

    // MARK: HTML and XML tags

    /// Rewrites the HTML and XML tags in a Markdown text as Markdown, so they are drawn and not shown as tags:
    /// - HTML: headings, paragraphs, line breaks, bold, italics, strikethrough, code, lists, quotes, rules, links and
    ///   images (as links) become their Markdown; layout-only tags (span, div…) are dropped and their text kept.
    /// - Other tags that are closed somewhere in the text (`<findings>…</findings>`, as the AI writes them) or
    ///   self-closed: one alone on its line becomes a bold label ("Findings"); inline ones are dropped, text kept.
    /// - Anything else in angle brackets (`List<String>`, `a < b`, `<https://…>`) is left as written.
    /// Fenced code and code spans are not touched. `&amp;`-style entities are decoded.
    static func normalizeHTML(_ source: String) -> String {
        guard source.contains("<") || source.contains("&") else { return source }
        guard let tag = try? NSRegularExpression(pattern: "<(/?)([A-Za-z][A-Za-z0-9_.:-]*)((?:\\s[^<>]*?)?)(/?)>"),
              let anchor = try? NSRegularExpression(pattern: "<a\\s[^<>]*?href\\s*=\\s*[\"']([^\"']*)[\"'][^<>]*>(.*?)</a\\s*>", options: [.caseInsensitive])
        else { return source }
        var text = source.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(script|style)\\b[\\s\\S]*?</\\1\\s*>", with: "", options: [.regularExpression, .caseInsensitive])
        // <pre><code> is one code block, not a block with a code span in it.
        text = text.replacingOccurrences(of: "<pre[^<>]*>\\s*<code[^<>]*>", with: "<pre>", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</code\\s*>\\s*</pre\\s*>", with: "</pre>", options: [.regularExpression, .caseInsensitive])
        // The names that have a closing tag: those are tags, whatever they are called.
        var closed: Set<String> = []
        let ns = text as NSString
        for m in tag.matches(in: text, range: NSRange(location: 0, length: ns.length)) where ns.substring(with: m.range(at: 1)) == "/" {
            closed.insert(ns.substring(with: m.range(at: 2)).lowercased())
        }
        var out: [String] = []
        var fenced: String? = nil
        for raw in text.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if let f = fenced {
                out.append(raw)
                if t.hasPrefix(f) { fenced = nil }
                continue
            }
            if let f = fence(t) { fenced = f; out.append(raw); continue }
            guard raw.contains("<") || raw.contains("&") else { out.append(raw); continue }
            let flat = t.hasPrefix("|")   // a table row stays on one line
            let parts = raw.components(separatedBy: "`")
            if parts.count % 2 == 0 || parts.count == 1 {
                out.append(convert(raw, alone: true, flat: flat, closed: closed, tag: tag, anchor: anchor))
            } else {
                // Odd pieces are code spans: left as written.
                var line: [String] = []
                for (i, piece) in parts.enumerated() {
                    line.append(i % 2 == 0 ? convert(piece, alone: false, flat: flat, closed: closed, tag: tag, anchor: anchor) : piece)
                }
                out.append(line.joined(separator: "`"))
            }
        }
        return out.joined(separator: "\n")
    }

    /// One stretch of text outside code: its tags rewritten, its entities decoded.
    private static func convert(_ s: String, alone: Bool, flat: Bool, closed: Set<String>, tag: NSRegularExpression, anchor: NSRegularExpression) -> String {
        var text = s
        if text.contains("<") {
            text = anchor.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "[$2]($1)")
            let ns = text as NSString
            let whole = text.trimmingCharacters(in: .whitespaces)
            var result = ""
            var at = 0
            for m in tag.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: at, length: m.range.location - at))
                let found = ns.substring(with: m.range)
                let closing = ns.substring(with: m.range(at: 1)) == "/"
                let name = ns.substring(with: m.range(at: 2)).lowercased()
                let attrs = ns.substring(with: m.range(at: 3))
                let selfClosing = ns.substring(with: m.range(at: 4)) == "/"
                if let r = replacement(name: name, closing: closing, attrs: attrs, selfClosing: selfClosing, alone: alone && whole == found, closed: closed) {
                    result += flat ? r.replacingOccurrences(of: "\n", with: " ") : r
                } else {
                    result += "\\" + found   // not a tag: shown as written
                }
                at = m.range.location + m.range.length
            }
            result += ns.substring(from: at)
            text = result
        }
        return entities(text)
    }

    /// The Markdown for one tag, or nil when it is not a tag (it has no closing tag and is not HTML).
    private static func replacement(name: String, closing: Bool, attrs: String, selfClosing: Bool, alone: Bool, closed: Set<String>) -> String? {
        switch name {
        case "br": return closing ? "" : "\n"
        case "b", "strong": return "**"
        case "i", "em", "cite", "var": return "*"
        case "s", "del", "strike": return "~~"
        case "code", "kbd", "tt", "samp": return "`"
        case "p", "div", "ul", "ol", "dl", "table", "section", "article", "details": return "\n\n"
        case "h1", "h2", "h3", "h4", "h5", "h6":
            return closing ? "\n\n" : "\n\n" + String(repeating: "#", count: Int(String(name.dropFirst())) ?? 1) + " "
        case "li": return closing ? "" : "\n- "
        case "dt", "dd", "tr": return closing ? "" : "\n"
        case "td", "th": return closing ? "   " : ""
        case "blockquote": return closing ? "\n\n" : "\n\n> "
        case "pre": return "\n```\n"
        case "hr": return closing ? "" : "\n\n---\n\n"
        case "summary": return closing ? "**\n\n" : "\n\n**"
        case "img":
            guard let src = attribute("src", in: attrs), !src.isEmpty else { return "" }
            let alt = attribute("alt", in: attrs) ?? ""
            return "[" + (alt.isEmpty ? "image" : alt) + "](" + src + ")"
        case "a", "u", "span", "font", "small", "big", "sup", "sub", "mark", "ins", "abbr", "center", "html", "head", "body", "main",
             "header", "footer", "nav", "tbody", "thead", "tfoot", "label", "title", "meta", "link", "figure", "figcaption", "caption",
             "colgroup", "col":
            return ""
        default:
            guard closed.contains(name) || selfClosing else { return nil }
            if closing || selfClosing || !alone { return "" }
            let label = name.replacingOccurrences(of: "[_.:-]+", with: " ", options: .regularExpression)
            return "\n\n**" + label.prefix(1).uppercased() + String(label.dropFirst()) + "**\n\n"
        }
    }

    /// The value of one attribute in a tag's attribute text.
    private static func attribute(_ name: String, in attrs: String) -> String? {
        guard let r = attrs.range(of: "\\b" + name + "\\s*=\\s*[\"'][^\"']*[\"']", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let found = attrs[r]
        guard let quote = found.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        return String(found[found.index(after: quote)...].dropLast())
    }

    private static func entities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var t = s
        let table: [(String, String)] = [("&nbsp;", " "), ("&lt;", "\\<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")]
        for (entity, plain) in table { t = t.replacingOccurrences(of: entity, with: plain) }
        return t
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
