import Foundation

/// What an item carries, shown as small glyphs inside its mark (the oval): a date, notes, web links, links to other
/// items, photos. The order here is the order they are drawn in, and the order they are kept in when the mark is
/// too short for all of them (the last ones are dropped).
enum MarkIndicator: String, CaseIterable, Identifiable {
    case date, note, link, itemLink, photo
    var id: String { rawValue }

    /// SF Symbol drawn in the mark.
    var symbol: String {
        switch self {
        case .date: "calendar"
        case .note: "text.alignleft"
        case .link: "link"
        case .itemLink: "arrow.left.arrow.right"   // same glyph as ItemLink.symbol
        case .photo: "photo.fill"
        }
    }
    /// Spoken name, and the legend's label.
    var label: String {
        switch self {
        case .date: "date"; case .note: "notes"; case .link: "web link"; case .itemLink: "linked item"; case .photo: "photo"
        }
    }

    /// Width one glyph takes in the mark.
    static let pitch: Double = 10
    /// Space kept clear at a round end of the mark that holds nothing else.
    static let endInset: Double = 3

    /// Everything the item carries, in drawing order. `checkable`: the mark has a check box, which already says the
    /// item has a date, so no date glyph is added.
    static func present(hasDate: Bool, hasNotes: Bool, webLinks: Int, itemLinks: Int, photos: Int, checkable: Bool) -> [MarkIndicator] {
        var out: [MarkIndicator] = []
        if hasDate && !checkable { out.append(.date) }
        if hasNotes { out.append(.note) }
        if webLinks > 0 { out.append(.link) }
        if itemLinks > 0 { out.append(.itemLink) }
        if photos > 0 { out.append(.photo) }
        return out
    }

    /// How many glyphs fit in a mark `width` wide whose ends are `cell` wide: the check box takes the left end, the AI
    /// glyph the right end.
    static func capacity(width: Double, cell: Double, checkable: Bool, aiGlyph: Bool) -> Int {
        let free = width - (checkable ? cell : endInset) - (aiGlyph ? cell : endInset)
        return max(0, Int((free / pitch).rounded(.down)))
    }

    /// The glyphs that are drawn: the first ones that fit.
    static func fitting(_ all: [MarkIndicator], width: Double, cell: Double, checkable: Bool, aiGlyph: Bool) -> [MarkIndicator] {
        Array(all.prefix(capacity(width: width, cell: cell, checkable: checkable, aiGlyph: aiGlyph)))
    }
}
