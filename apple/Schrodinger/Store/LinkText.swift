import Foundation

/// Finds web addresses typed into an item's text, so they can be shown apart from the text as link chips.
/// Only words that are plainly links count: ones starting with http://, https:// or www. ("README.md" stays text).
enum LinkText {
    /// Takes the links out of `text`. `rest` is the text without them; `links` are the words that were links.
    static func extract(from text: String) -> (rest: String, links: [String]) {
        var links: [String] = []
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let words = line.split(separator: " ", omittingEmptySubsequences: false).filter { word in
                let w = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)(<>\"'"))
                let low = w.lowercased()
                guard low.hasPrefix("http://") || low.hasPrefix("https://") || low.hasPrefix("www."),
                      Attachment.normalizedURL(w) != nil else { return true }
                links.append(w)
                return false
            }
            return links.isEmpty ? line : words.joined(separator: " ").replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        return (lines.joined(separator: "\n"), links)
    }
}
