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
}

/// One control on the bottom edge of the item field: a bare glyph, no capsule. `on` draws it at full strength
/// (a state, or the main action); the rest are quieter so the text stays the loudest thing in the field.
struct FieldIcon: View {
    let systemImage: String
    var on = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.ink.opacity(!enabled ? 0.2 : on ? 0.9 : 0.5))
                .frame(width: ItemField.icon, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// In the item field, above its controls: the AI's draft, when it has written one. The item's notes are not repeated
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
                Text(node.state == .review ? "DRAFT · AWAITING REVIEW" : "DRAFT")
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
