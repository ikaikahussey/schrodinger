import SwiftUI

/// Color schemes for the outline squares. Each scheme gives one color per mode and a rotating set of context colors
/// (one per top-level project). "Mono" keeps the original black-on-white look.
enum PaletteKind: String, CaseIterable, Identifiable {
    case mono, lcars, okabeIto, reef, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mono: "Mono"; case .lcars: "LCARS"; case .okabeIto: "Color-blind safe"; case .reef: "Reef"; case .custom: "Custom"
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
    static let lcars = Palette(
        modes: ["FF9900", "CC6666", "9999FF", "FFCC99", "99CCFF", "CC99CC", "FFCC00", "A0A0A0"].map(Color.init(hex:)),
        contexts: ["FF9966", "CC99CC", "9999CC", "FFAA00", "6688CC", "DD8866"].map(Color.init(hex:)))
    static let okabeIto = Palette(
        modes: ["E69F00", "D55E00", "0072B2", "CC79A7", "56B4E9", "009E73", "F0E442", "999999"].map(Color.init(hex:)),
        contexts: ["0072B2", "E69F00", "009E73", "CC79A7", "56B4E9", "D55E00"].map(Color.init(hex:)))
    static let reef = Palette(
        modes: ["F78154", "B4436C", "0B6E99", "8E7DBE", "1BA39C", "F2C14E", "4D9078", "9AA5AB"].map(Color.init(hex:)),
        contexts: ["0B6E99", "1BA39C", "4D9078", "F2C14E", "F78154", "8E7DBE"].map(Color.init(hex:)))

    static func preset(_ k: PaletteKind) -> Palette {
        switch k { case .mono: .mono; case .lcars: .lcars; case .okabeIto: .okabeIto; case .reef: .reef; case .custom: .lcars }
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
        palette = PaletteKind(rawValue: d.string(forKey: "palette") ?? "") ?? .lcars
        font = AppFontFamily(rawValue: d.string(forKey: "fontFamily") ?? "") ?? .system
        sounds = d.object(forKey: "outlineSounds") as? Bool ?? true
        let env = EnvironmentValues()
        customModes = Self.load("customModeColors", count: Palette.modeCount) ?? Palette.lcars.modes.map { $0.resolve(in: env) }
        customContexts = Self.load("customContextColors", count: Palette.contextCount) ?? Palette.lcars.contexts.map { $0.resolve(in: env) }
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
