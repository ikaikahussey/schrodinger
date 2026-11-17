import Foundation

/// Finds list lines in typed text, so a list started in an item's field can become child items.
/// A list line is `- text`, `* text`, `• text`, `+ text`, `1. text` or `1) text`, optionally indented and
/// optionally starting with a checkbox (`[ ]` or `[x]`).
enum ListText {
    struct Item: Equatable {
        /// Leading whitespace, in spaces (a tab counts as 4). Deeper lines nest under shallower ones.
        var indent: Int
        var title: String
        var done = false
    }

    /// The list item a line holds, or nil if the line is not a list line (or has no text after its marker).
    static func item(_ line: String) -> Item? {
        var indent = 0
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" { indent += line[i] == "\t" ? 4 : 1; i = line.index(after: i) }
        var s = line[i...]
        if let f = s.first, "-*•+".contains(f) {
            s = s.dropFirst()
        } else {
            let digits = s.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 3 else { return nil }
            s = s.dropFirst(digits.count)
            guard let p = s.first, p == "." || p == ")" else { return nil }
            s = s.dropFirst()
        }
        guard let gap = s.first, gap == " " || gap == "\t" else { return nil }
        var text = s.trimmingCharacters(in: .whitespaces)
        var done = false
        for (box, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] where text.hasPrefix(box) {
            text = String(text.dropFirst(box.count)).trimmingCharacters(in: .whitespaces); done = checked; break
        }
        return text.isEmpty ? nil : Item(indent: indent, title: text, done: done)
    }

    /// Takes the list lines out of `text`. A line still being typed (the last one) is left alone unless
    /// `includeLastLine`. Lines in `keeping` are never taken (text that was already there before the edit).
    static func extract(from text: String, includeLastLine: Bool, keeping: Set<String> = []) -> (rest: String, items: [Item]) {
        let lines = text.components(separatedBy: "\n")
        var items: [Item] = [], rest: [String] = []
        for (n, line) in lines.enumerated() {
            let finished = includeLastLine || n < lines.count - 1
            if finished, !keeping.contains(line), let it = item(line) { items.append(it) } else { rest.append(line) }
        }
        return (rest.joined(separator: "\n"), items)
    }
}
