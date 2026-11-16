import AVFoundation

/// Note numbers (MIDI) for outline moves.
///   Indent / outdent: each level of depth is one step up a major (diatonic) scale from C5.
///   Move up / down: one semitone per row (chromatic); moving up raises the pitch.
enum OutlinePitch {
    static let base = 72                       // C5
    static let major = [0, 2, 4, 5, 7, 9, 11]
    static let lowest = 60                     // C4
    static let highest = 108                   // C8

    /// Diatonic note for an outline depth (0 = top level).
    static func depth(_ d: Int) -> Int {
        let d = max(0, d)
        return clamp(base + 12 * (d / 7) + major[d % 7])
    }
    /// Chromatic note for a sibling position under a given depth: the first sibling is the depth's note, each row
    /// below it one semitone lower.
    static func position(_ p: Int, depth d: Int) -> Int { clamp(depth(d) - max(0, p)) }
    /// Chromatic note for a row in the visible outline while dragging (row 0 = top, one octave above base).
    static func row(_ r: Int) -> Int { clamp(base + 12 - max(0, r)) }

    static func clamp(_ m: Int) -> Int { min(highest, max(lowest, m)) }
    static func frequency(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }
}

/// Synthesized xylophone: a mallet click plus the bar's fundamental and its tuned overtones (3× and ~6×), each
/// decaying quickly. Buffers are rendered once per note and cached. Plays through the ambient audio session, so the
/// ring/silent switch and other audio are respected.
@MainActor
final class Xylophone {
    static let shared = Xylophone()
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var cache: [Int: AVAudioPCMBuffer] = [:]
    private let sampleRate = 44_100.0
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
    private var lastNote: Int? = nil
    private var lastTime = Date.distantPast

    private init() {}

    func play(_ midi: Int) {
        guard Appearance.shared.sounds else { return }
        // Ignore immediate repeats of the same note (layout passes can report the same drag target twice).
        let now = Date()
        if lastNote == midi && now.timeIntervalSince(lastTime) < 0.06 { return }
        lastNote = midi; lastTime = now
        guard prepare(), let buf = buffer(midi) else { return }
        let p = players[next]; next = (next + 1) % players.count
        p.stop()
        p.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        p.play()
    }

    private func prepare() -> Bool {
        if engine.isRunning { return true }
        guard let format else { return false }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        if players.isEmpty {
            for _ in 0..<6 {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: format)
                players.append(p)
            }
        }
        do { try engine.start(); return true } catch { return false }
    }

    private func buffer(_ midi: Int) -> AVAudioPCMBuffer? {
        if let b = cache[midi] { return b }
        guard let format else { return nil }
        let seconds = 0.9
        let n = AVAudioFrameCount(sampleRate * seconds)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n), let out = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = n
        let f = OutlinePitch.frequency(midi)
        // (frequency ratio, amplitude, decay time constant in seconds)
        let partials: [(Double, Double, Double)] = [(1, 1.0, 0.32), (3.0, 0.32, 0.10), (6.1, 0.10, 0.04), (9.8, 0.04, 0.02)]
        var seed: UInt32 = 0x9E37_79B9
        for i in 0..<Int(n) {
            let t = Double(i) / sampleRate
            var s = 0.0
            for (r, a, tau) in partials where f * r < sampleRate / 2 {
                s += a * exp(-t / tau) * sin(2 * .pi * f * r * t)
            }
            // Mallet click: a few milliseconds of decaying noise.
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            s += 0.12 * exp(-t / 0.003) * noise
            let attack = min(1, t / 0.002)
            out[i] = Float(0.28 * attack * s)
        }
        cache[midi] = buf
        return buf
    }
}
