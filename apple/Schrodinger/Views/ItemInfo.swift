import SwiftUI
import SwiftData

// The item field: what an open item's row becomes (tap its text or its squares). One rounded block holds the text,
// the notes, the AI's draft when there is one, and the controls as bare glyphs along the bottom edge.

/// Colors for the app's own controls (header blocks, search field, filter button, tag buttons, the + button, the
/// item sheet). They come from the color scheme chosen in Settings, so every control follows the scheme.
/// The five names are slots, kept from the first design; each maps to one of the scheme's project colors.
@MainActor
enum PanelPalette {
    private static var scheme: [Color] { let c = Appearance.shared.current.contexts; return c.isEmpty ? [.primary] : c }
    private static func slot(_ i: Int) -> Color { let c = scheme; return c[i % c.count] }
    /// Main accent (the + button, the filter button).
    static var orange: Color { slot(0) }
    /// "On" state (active search, active filter, the current breadcrumb, a selected pill).
    static var peach: Color { slot(1) }
    static var lavender: Color { slot(2) }
    static var periwinkle: Color { slot(3) }
    static var rose: Color { slot(4) }
    /// Backing for the item sheet: a light wash of the text color.
    static var field: Color { Color.ink.opacity(0.07) }
    static var all: [Color] { (0..<5).map(slot) }
    /// A stable color for a control, picked from what it shows, so neighbours differ but nothing flickers.
    static func color(for key: String) -> Color {
        let a = all
        return a[Int(key.unicodeScalars.reduce(UInt32(0)) { ($0 &* 31) &+ $1.value } % UInt32(a.count))]
    }
    /// Text or glyph color that reads on `fill`: the background color on a text-colored block, otherwise black or
    /// white by the fill's brightness.
    static func text(on fill: Color) -> Color {
        if fill == Color.primary { return Color.canvas }
        let r = fill.resolve(in: EnvironmentValues())
        let luminance = 0.2126 * Double(r.linearRed) + 0.7152 * Double(r.linearGreen) + 0.0722 * Double(r.linearBlue)
        return luminance > 0.30 ? .black : .white
    }
    static func label(_ style: Font.TextStyle = .caption) -> Font { .system(style, design: .default, weight: .bold).width(.condensed) }
}

/// A slow, soft pulse for the panel's color blocks: each block dims slightly and comes back, on its own period, so
/// the display looks live without flashing. Off when Reduce Motion is on.
struct PanelBlink: ViewModifier {
    /// Picks the block's period and phase; neighbours should use different numbers.
    let seed: Int
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion, !dim else { return }
                let period = 1.8 + Double(seed % 5) * 0.45          // 1.8 – 3.6 s per half cycle
                let delay = Double((seed * 7) % 11) * 0.3            // 0 – 3 s before the first dim
                withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true).delay(delay)) { dim = true }
            }
    }
}
extension View {
    /// Gentle blink for a panel color block. See `PanelBlink`.
    func panelBlink(_ seed: Int) -> some View { modifier(PanelBlink(seed: seed)) }
}

extension EnvironmentValues {
    /// True inside the item sheet: pills draw as flat capsules in the scheme's colors.
    @Entry var panelStyle = false
}

/// Measures of the item field: the rounded block an open item's text sits in, with its controls along the bottom.
enum ItemField {
    /// Space between the field's edge and its text, left and right.
    static let inset: CGFloat = 10
    static let top: CGFloat = 8
    /// Width of one control's touch area.
    static let icon: CGFloat = 40
    /// Width of a control on the title line (narrower, so the title keeps its room).
    static let compact: CGFloat = 30
}

/// One control on the bottom edge of the item field: a bare glyph, no capsule. `on` draws it at full strength
/// (a state, or the main action); the rest are quieter so the text stays the loudest thing in the field.
struct FieldIcon: View {
    let systemImage: String
    var on = false
    var width: CGFloat = ItemField.icon
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.ink.opacity(!enabled ? 0.2 : on ? 0.9 : 0.5))
                .frame(width: width, height: width == ItemField.compact ? 22 : 34)   // on the title line: text height
                .contentShape(Rectangle().inset(by: width == ItemField.compact ? -6 : 0))
        }
        .buttonStyle(.plain)
    }
}

/// A filled circle with one glyph, on the item field's bottom edge: the + button's look at the field's size.
struct FieldCircle: View {
    let systemImage: String
    let fill: Color
    /// On the title line: a smaller circle in a narrower slot, no taller than the text.
    var compact = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 11 : 13, weight: .bold))
                .foregroundStyle(PanelPalette.text(on: fill))
                .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                .background { Circle().fill(fill).panelBlink(34) }
                .opacity(enabled ? 1 : 0.35)
                .frame(width: compact ? ItemField.compact : ItemField.icon, height: compact ? 22 : 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The child count in the control strip: a two-part capsule in the scheme's main color. The left block carries the
/// outline glyph, the right the number in the panel's condensed bold digits, two wide ("03") so the badge keeps its
/// size as the count changes. Filled while the children are on screen, outlined while they are hidden; tap to
/// show or hide them.
struct ChildCountBadge: View {
    let count: Int
    /// The children are on screen.
    var shown = true
    let action: () -> Void

    private var fill: Color { PanelPalette.orange }
    private var digits: String { count < 10 ? "0\(count)" : "\(count)" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // Left block: always solid, with the glyph cut in the color that reads on it.
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(PanelPalette.text(on: fill))
                    .frame(width: 22, height: 20)
                    .background { fill.panelBlink(41) }
                // Right block: the number. Solid when the children are shown, open when they are hidden.
                Text(digits)
                    .font(PanelPalette.label(.caption).monospacedDigit())
                    .foregroundStyle(shown ? PanelPalette.text(on: fill) : Color.ink.opacity(0.85))
                    .padding(.leading, 5).padding(.trailing, 8)
                    .frame(minWidth: 26, minHeight: 20)
                    .background { if shown { fill.opacity(0.78) } }
            }
            .clipShape(Capsule())
            .overlay { Capsule().strokeBorder(fill, lineWidth: 1.5) }
            .frame(height: 22)
            .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .help("\(count) " + (count == 1 ? "child" : "children") + (shown ? " · tap to hide" : " · tap to show"))
        .accessibilityLabel("\(count) " + (count == 1 ? "child" : "children"))
        .accessibilityHint(shown ? "Hides the children" : "Shows the children")
    }
}

/// One AI suggestion in the item field: what it is, what accepting it would do, and the two buttons that answer it
/// (accept, dismiss). A remark with nothing to apply has only dismiss.
struct SuggestionRow: View {
    let proposal: Proposal
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        // Reading a deleted model traps; the row can render once more after it is answered.
        if proposal.isDeleted || proposal.modelContext == nil { EmptyView() } else { content }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.45)).padding(.top, 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.summary).font(Appearance.shared.font.font(.body)).foregroundStyle(Color.ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                if let d = detail {
                    Text(d).font(Appearance.shared.font.font(.body)).foregroundStyle(Color.ink.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            if !proposal.isInformational {
                FieldIcon(systemImage: "checkmark", on: true, width: 34, action: onAccept).help("Accept").accessibilityLabel("Accept suggestion")
            }
            FieldIcon(systemImage: "xmark", width: 34, action: onDismiss).help("Dismiss").accessibilityLabel("Dismiss suggestion")
        }
        .accessibilityElement(children: .contain)
    }

    /// What accepting would add or change.
    private var detail: String? {
        let pl = proposal.payload
        switch proposal.type {
        case .decompose:
            let titles = (pl["subtasks"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
            return titles.isEmpty ? nil : titles.map { "+ " + $0 }.joined(separator: "\n")
        case .new_task: return (pl["title"] as? String).map { "+ " + $0 }
        case .retitle: return (pl["title"] as? String).map { "\u{201C}" + $0 + "\u{201D}" }
        case .note: return pl["text"] as? String
        case .reassign: return (pl["assignee"] as? String).flatMap(Assignee.init(rawValue:)).map { "\u{2192} " + $0.label }
        case .stale, .blocked_chain, .no_path, .feedback: return nil
        }
    }
}

/// In the item field, above its controls: the AI's result, when it has handed one in. The item's notes are not repeated
/// here; they are read and edited inline in the row.
struct ItemSheetBody: View {
    @Bindable var node: Node

    var body: some View {
        // Reading a deleted model traps; this view can render once more after Delete.
        if node.isDeleted || node.modelContext == nil { EmptyView() } else { content }
    }

    @ViewBuilder private var content: some View {
        if let a = node.artifact, !a.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(node.state == .review ? "RESULT · NEEDS YOU" : "RESULT")
                    .font(PanelPalette.label(.caption2)).foregroundStyle(Color.ink.opacity(0.55))
                ScrollView {
                    Text(a).font(.system(.callout, design: .monospaced)).foregroundStyle(Color.ink)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
        }
    }
}
