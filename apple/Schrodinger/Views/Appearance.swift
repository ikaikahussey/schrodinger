import SwiftUI

/// Color schemes for the outline squares. Each scheme gives one color per mode and a rotating set of context colors
/// (one per top-level project). "Retro 70s" is the default; "Mono" keeps the original black-on-white look.
enum PaletteKind: String, CaseIterable, Identifiable {
    // "pastel" keeps its original stored value so a saved choice of this scheme still loads.
    case retro70s, swiss, mono, pastel = "lcars", okabeIto, reef, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .retro70s: "Retro 70s"; case .swiss: "Swiss"; case .mono: "Mono"; case .pastel: "Pastel"; case .okabeIto: "Color-blind safe"; case .reef: "Reef"; case .custom: "Custom"
        }
    }
}

struct Palette {
    /// Indexed by `Mode.allCases` order: call, errand, email, write, research, meeting, admin, other.
    var modes: [Color]
    /// Rotating colors for top-level projects (contexts).
    var contexts: [Color]

    static let modeCount = Mode.allCases.count
    static let contextCount = 6

    static let mono = Palette(modes: Array(repeating: .primary, count: modeCount), contexts: Array(repeating: .primary, count: contextCount))
    /// Earth tones of 1970s interiors and print: burnt orange, rust, teal, mustard, avocado, plum, tan, brown.
    static let retro70s = Palette(
        modes: ["CC5803", "A63D40", "2A7F86", "E3A72F", "7A8B3C", "7B3F61", "C9A66B", "6F4E37"].map(Color.init(hex:)),
        contexts: ["CC5803", "E3A72F", "7A8B3C", "2A7F86", "A63D40", "6F4E37"].map(Color.init(hex:)))
    /// Swiss poster style: signal red and black on white, nothing else. "Black" is the text color, so in dark mode
    /// the scheme reads as red and white on black. Modes and projects alternate between the two.
    static let swiss: Palette = {
        let red = Color(hex: "E30613"), ink = Color.primary
        return Palette(modes: [red, ink, red, ink, red, ink, red, ink], contexts: [red, ink, red, ink, red, ink])
    }()
    static let pastel = Palette(
        modes: ["FF9900", "CC6666", "9999FF", "FFCC99", "99CCFF", "CC99CC", "FFCC00", "A0A0A0"].map(Color.init(hex:)),
        contexts: ["FF9966", "CC99CC", "9999CC", "FFAA00", "6688CC", "DD8866"].map(Color.init(hex:)))
    static let okabeIto = Palette(
        modes: ["E69F00", "D55E00", "0072B2", "CC79A7", "56B4E9", "009E73", "F0E442", "999999"].map(Color.init(hex:)),
        contexts: ["0072B2", "E69F00", "009E73", "CC79A7", "56B4E9", "D55E00"].map(Color.init(hex:)))
    static let reef = Palette(
        modes: ["F78154", "B4436C", "0B6E99", "8E7DBE", "1BA39C", "F2C14E", "4D9078", "9AA5AB"].map(Color.init(hex:)),
        contexts: ["0B6E99", "1BA39C", "4D9078", "F2C14E", "F78154", "8E7DBE"].map(Color.init(hex:)))

    static func preset(_ k: PaletteKind) -> Palette {
        switch k { case .retro70s: .retro70s; case .swiss: .swiss; case .mono: .mono; case .pastel: .pastel; case .okabeIto: .okabeIto; case .reef: .reef; case .custom: .retro70s }
    }
}

/// Sans-serif typefaces available on every iOS and macOS device without bundling.
enum AppFontFamily: String, CaseIterable, Identifiable {
    case system, rounded, helveticaNeue, avenirNext, futura, gillSans
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "San Francisco"; case .rounded: "SF Rounded"; case .helveticaNeue: "Helvetica Neue"
        case .avenirNext: "Avenir Next"; case .futura: "Futura"; case .gillSans: "Gill Sans"
        }
    }
    var familyName: String? {
        switch self {
        case .system, .rounded: nil; case .helveticaNeue: "Helvetica Neue"; case .avenirNext: "Avenir Next"; case .futura: "Futura"; case .gillSans: "Gill Sans"
        }
    }
    func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .system: return .system(style, design: .default, weight: weight)
        case .rounded: return .system(style, design: .rounded, weight: weight)
        default: return .custom(familyName ?? "", size: Self.size(style), relativeTo: style).weight(weight)
        }
    }
    /// Default point sizes for each text style; Dynamic Type scales from these.
    static func size(_ s: Font.TextStyle) -> CGFloat {
        #if os(macOS)
        switch s { case .largeTitle: 26; case .title: 22; case .title2: 17; case .title3: 15; case .headline, .body: 13; case .callout: 12; case .subheadline: 11; case .footnote: 10; case .caption: 10; case .caption2: 10; @unknown default: 13 }
        #else
        switch s { case .largeTitle: 34; case .title: 28; case .title2: 22; case .title3: 20; case .headline, .body: 17; case .callout: 16; case .subheadline: 15; case .footnote: 13; case .caption: 12; case .caption2: 11; @unknown default: 17 }
        #endif
    }
}

/// User-chosen look and sound, persisted in UserDefaults.
@MainActor
@Observable
final class Appearance {
    static let shared = Appearance()
    private let d = UserDefaults.standard

    var palette: PaletteKind { didSet { d.set(palette.rawValue, forKey: "palette") } }
    var font: AppFontFamily { didSet { d.set(font.rawValue, forKey: "fontFamily") } }
    var sounds: Bool { didSet { d.set(sounds, forKey: "outlineSounds") } }
    /// Custom scheme colors, stored as resolved sRGB values.
    var customModes: [Color.Resolved] { didSet { store(customModes, "customModeColors") } }
    var customContexts: [Color.Resolved] { didSet { store(customContexts, "customContextColors") } }

    private init() {
        palette = PaletteKind(rawValue: d.string(forKey: "palette") ?? "") ?? .retro70s   // default scheme
        font = AppFontFamily(rawValue: d.string(forKey: "fontFamily") ?? "") ?? .helveticaNeue
        sounds = d.object(forKey: "outlineSounds") as? Bool ?? true
        let env = EnvironmentValues()
        customModes = Self.load("customModeColors", count: Palette.modeCount) ?? Palette.retro70s.modes.map { $0.resolve(in: env) }
        customContexts = Self.load("customContextColors", count: Palette.contextCount) ?? Palette.retro70s.contexts.map { $0.resolve(in: env) }
    }

    var current: Palette {
        palette == .custom ? Palette(modes: customModes.map { Color($0) }, contexts: customContexts.map { Color($0) }) : .preset(palette)
    }
    func color(for mode: Mode) -> Color {
        let i = Mode.allCases.firstIndex(of: mode) ?? 0
        let m = current.modes
        return m.isEmpty ? .primary : m[i % m.count]
    }
    func contextColor(_ index: Int) -> Color {
        let c = current.contexts
        return c.isEmpty ? .primary : c[((index % c.count) + c.count) % c.count]
    }
    /// An item's color, the same scheme in every project. The level picks the color: top-level items color A, their
    /// children color B, the next level C, and so on (the scheme's colors in order). Then the item's details tint it:
    ///   to-do    — a reddish tint;
    ///   has notes — a green tint;
    ///   AI holds it — a darker shade (shared: a little darker).
    /// A gray scheme (Mono, Swiss black) shows only the AI shade, as strength, so it still follows light and dark mode.
    func itemColor(depth: Int, state: TaskState, hasNotes: Bool, assignee: Assignee) -> Color {
        let base = contextColor(max(depth, 0))
        let darker: Double = switch assignee { case .ai: 0.68; case .shared: 0.84; case .human, .unassigned: 1 }
        let r = base.resolve(in: EnvironmentValues())
        var rgb = (Double(r.red), Double(r.green), Double(r.blue))
        if Self.hsb(rgb.0, rgb.1, rgb.2).1 < 0.08 { return base.opacity(0.55 + 0.45 * (1 - darker) / 0.32) }
        func mix(_ t: (Double, Double, Double), _ k: Double) { rgb = (rgb.0 + (t.0 - rgb.0) * k, rgb.1 + (t.1 - rgb.1) * k, rgb.2 + (t.2 - rgb.2) * k) }
        if state == .todo { mix((0.84, 0.16, 0.16), 0.3) }      // reddish
        if hasNotes { mix((0.18, 0.62, 0.27), 0.3) }             // green
        rgb = (rgb.0 * darker, rgb.1 * darker, rgb.2 * darker)
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
    private static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = (g - b) / d } else if mx == g { h = 2 + (b - r) / d } else { h = 4 + (r - g) / d }
            h /= 6; if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    /// Copy a preset into the custom slots (starting point for editing).
    func copyToCustom(_ k: PaletteKind) {
        let env = EnvironmentValues(), p = Palette.preset(k)
        customModes = p.modes.map { $0.resolve(in: env) }
        customContexts = p.contexts.map { $0.resolve(in: env) }
    }

    private func store(_ v: [Color.Resolved], _ key: String) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
    }
    private static func load(_ key: String, count: Int) -> [Color.Resolved]? {
        guard let data = UserDefaults.standard.data(forKey: key), let v = try? JSONDecoder().decode([Color.Resolved].self, from: data), v.count == count else { return nil }
        return v
    }
}

extension Color {
    /// sRGB color from a 6-digit hex string such as "FF9900".
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: 1)
    }
}
