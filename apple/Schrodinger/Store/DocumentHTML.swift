import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A result's Markdown as HTML, for apps that take formatted text from the clipboard (Google Docs, Word, Pages,
/// Mail): headings, paragraphs, lists, quotes, code, rules and tables, with bold, italics, code spans,
/// strikethrough and links inside them.
enum DocumentHTML {
    static func html(markdown: String) -> String {
        var out: [String] = ["<meta charset=\"utf-8\">"]
        var lists: [String] = []   // the list tags open now, outermost first
        func closeLists(to depth: Int = 0) { while lists.count > depth { out.append("</\(lists.removeLast())>") } }
        for block in Markdown.blocks(markdown) {
            if case .listItem(let depth, let marker, let text) = block {
                let tag: String
                var lead = ""
                switch marker {
                case .bullet: tag = "ul"
                case .number: tag = "ol"
                case .task(let done): tag = "ul"; lead = done ? "\u{2611} " : "\u{2610} "
                }
                closeLists(to: depth + 1)
                if lists.count == depth + 1, lists.last != tag { closeLists(to: depth) }
                while lists.count < depth + 1 { lists.append(tag); out.append("<\(tag)>") }
                out.append("<li>\(lead)\(inline(text))</li>")
                continue
            }
            closeLists()
            switch block {
            case .heading(let level, let text):
                let l = min(max(level, 1), 6)
                out.append("<h\(l)>\(inline(text))</h\(l)>")
            case .paragraph(let text): out.append("<p>\(inline(text).replacingOccurrences(of: "\n", with: "<br>"))</p>")
            case .quote(let text): out.append("<blockquote>\(inline(text).replacingOccurrences(of: "\n", with: "<br>"))</blockquote>")
            case .code(let text): out.append("<pre>\(escape(text))</pre>")
            case .rule: out.append("<hr>")
            case .table(let header, let rows):
                var t = "<table border=\"1\"><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr>"
                for r in rows { t += "<tr>" + r.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }
                out.append(t + "</table>")
            case .listItem: break
            }
        }
        closeLists()
        return out.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The inline marks of one block's text, as HTML.
    static func inline(_ text: String) -> String {
        var t = escape(text)
        let rules: [(String, String)] = [
            ("`([^`]+)`", "<code>$1</code>"),
            ("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>"),
            ("\\*\\*(.+?)\\*\\*", "<b>$1</b>"),
            ("(?<![\\w_])__(.+?)__(?![\\w_])", "<b>$1</b>"),
            ("(?<![\\*\\w])\\*(?!\\s)(.+?)(?<!\\s)\\*(?![\\*\\w])", "<i>$1</i>"),
            ("(?<![\\w_/])_(?!\\s)(.+?)(?<!\\s)_(?![\\w_])", "<i>$1</i>"),
            ("~~(.+?)~~", "<s>$1</s>"),
        ]
        for (pattern, template) in rules { t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression) }
        return t
    }
}

/// Text put on the clipboard both as formatted text (HTML) and as plain text: an app that takes formatting pastes
/// the first, any other the second.
@MainActor
enum Clipboard {
    static func copy(html: String, plain: String) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(html, forType: .html)
        pb.setString(plain, forType: .string)
        #else
        UIPasteboard.general.items = [["public.html": html, "public.utf8-plain-text": plain]]
        #endif
    }
}

/// Sending a result to Google Docs. The app has no Google sign-in, so it does not write to Drive itself: the piece
/// is put on the clipboard as formatted text and a new, empty Google Doc is opened to paste it into.
enum GoogleDocs {
    /// The address that opens a new Google Doc with this title.
    static func newDocument(title: String) -> URL? {
        var c = URLComponents(string: "https://docs.google.com/document/create")
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { c?.queryItems = [URLQueryItem(name: "title", value: name)] }
        return c?.url
    }
    /// A result as it leaves the app: without the links to items (they lead nowhere outside it) and without the
    /// list of threads.
    static func exported(_ markdown: String) -> String {
        WeaveLinks.pruned(WeaveLinks.withoutThreadList(markdown), valid: []).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
