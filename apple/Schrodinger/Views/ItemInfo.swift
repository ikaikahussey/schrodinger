import SwiftUI
import SwiftData

// The item sheet: opened by tapping an item's squares. It is the action strip plus one text field on a plain black
// panel, with flat colored capsule buttons. The decorative frame (rail, elbows, bars) lives only in the outline's
// breadcrumb bar and new-item button.

/// Panel palette. Fixed colors on black: the panel looks the same in light and dark mode.
enum PanelPalette {
    static let orange = Color(red: 1.00, green: 0.60, blue: 0.20)
    static let peach = Color(red: 1.00, green: 0.80, blue: 0.60)
    static let lavender = Color(red: 0.80, green: 0.60, blue: 0.80)
    static let periwinkle = Color(red: 0.60, green: 0.60, blue: 1.00)
    static let rose = Color(red: 0.80, green: 0.40, blue: 0.40)
    static let field = Color.black
    static let all = [orange, peach, lavender, periwinkle, rose]
    /// A stable color for a control, picked from what it shows, so neighbours differ but nothing flickers.
    static func color(for key: String) -> Color {
        all[Int(key.unicodeScalars.reduce(UInt32(0)) { ($0 &* 31) &+ $1.value } % UInt32(all.count))]
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
    /// True inside the item sheet: pills draw as flat colored capsules with black glyphs.
    @Entry var panelStyle = false
}

/// The sheet's container: a plain black panel. No rail, bars or labels; only the controls and the text field.
struct ItemPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelPalette.field, in: RoundedRectangle(cornerRadius: 14))
            .environment(\.panelStyle, true)
            .environment(\.colorScheme, .dark)   // menus and the text cursor read correctly on black
    }
}

/// The sheet's one text field, and — only when the AI has written one — its draft to read.
/// Tasks: the field is the item's context. Projects: the field is the goal (what the project's agent works toward).
struct ItemSheetBody: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var node: Node
    private var store: Store { Store(ctx) }

    var body: some View {
        // Reading a deleted model traps; this view can render once more after Delete.
        if node.isDeleted || node.modelContext == nil { EmptyView() } else { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if node.isProject {
                // Labeled like every other item's field. What is typed here is what the project's agent works toward.
                PanelText(placeholder: "NOTES", value: node.goal) { v in store.update(node) { $0.goal = v }; store.save() }
            } else {
                PanelText(placeholder: "NOTES", value: node.notes) { v in store.update(node) { $0.notes = v }; store.save() }
            }
            if let a = node.artifact, !a.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.state == .review ? "DRAFT · AWAITING REVIEW" : "DRAFT")
                        .font(PanelPalette.label(.caption2)).foregroundStyle(PanelPalette.periwinkle)
                    ScrollView {
                        Text(a).font(.system(.callout, design: .monospaced)).foregroundStyle(PanelPalette.peach)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                }
            }
        }
    }
}

/// Multi-line text that saves when editing ends (Return, focus leaves, or the view goes away) rather than on every
/// keystroke, so one edit is one undo step and one activity entry.
struct PanelText: View {
    let placeholder: String
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(PanelPalette.orange.opacity(0.45)), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(.body, design: .default, weight: .medium).width(.condensed))
            .foregroundStyle(PanelPalette.orange)
            .tint(PanelPalette.peach)
            .lineLimit(2...12)
            .focused($focused)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .overlay(alignment: .leading) { Rectangle().fill(focused ? PanelPalette.peach : PanelPalette.orange.opacity(0.6)).frame(width: 3) }
            .onAppear { text = value }
            .onChange(of: value) { _, v in if !focused { text = v } }
            .onChange(of: focused) { _, f in if !f { save() } }
            .onSubmit { save() }
            .onDisappear { save() }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != value { commit(t) }
    }
}
