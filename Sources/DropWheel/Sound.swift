import AVFoundation
import AppKit

// MARK: - Settings

enum SoundMode: String, CaseIterable {
    case off, subtle, drone

    var title: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle: soft ticks"
        case .drone: return "Drone: sci-fi chirps"
        }
    }
}

enum SoundEvent: CaseIterable {
    case appear   // wheel opens
    case commit   // file released on a segment
    case done     // conversion finished
    case error    // conversion failed
}

// MARK: - What every target sounds like
//
// The sound carries information: a target always has the same note, so you can tell which segment
// you're on without looking. Family decides register and timbre; position inside the family decides
// the note. Everything lives on one C-major pentatonic ladder, so any sequence of hovers sounds
// consonant. Lossy targets get a bit-crushed version of their own chirp.

struct Timbre {
    let baseStep: Int      // first step on the pentatonic ladder (0 = C3)
    let ratio: Double      // FM modulator : carrier
    let index: Double      // FM depth at the start of the note
    let partial: Double    // level of an octave-up partial
    let length: Double     // seconds
}

enum SoundFamily: CaseIterable {
    case images, documents, data, video, audio, tools

    /// Order inside a family is the order of notes, low to high.
    var members: [String] {
        switch self {
        case .images: return ["jpg", "png", "heic", "webp", "tiff", "gif", "bmp"]
        case .documents: return ["pdf", "docx", "odt", "rtf", "txt", "html", "md", "epub"]
        case .data: return ["csv", "xlsx", "json"]
        case .video: return ["mp4", "mov", "mkv", "webm"]
        case .audio: return ["mp3", "m4a", "wav", "aiff", "flac", "ogg"]
        case .tools: return ["merge", "split", "compress", "zip", "unpack", "sign"]
        }
    }

    var timbre: Timbre {
        switch self {
        case .images: return Timbre(baseStep: 11, ratio: 2.0, index: 1.8, partial: 0.00, length: 0.085)   // glassy, high
        case .documents: return Timbre(baseStep: 7, ratio: 1.0, index: 1.6, partial: 0.10, length: 0.090) // papery, mid
        case .data: return Timbre(baseStep: 9, ratio: 3.0, index: 2.0, partial: 0.00, length: 0.070)      // clicky, digital
        case .video: return Timbre(baseStep: 5, ratio: 1.5, index: 3.6, partial: 0.00, length: 0.110)     // bell-like sweep, low
        case .audio: return Timbre(baseStep: 13, ratio: 1.0, index: 0.25, partial: 0.20, length: 0.100)   // pure, round, highest
        case .tools: return Timbre(baseStep: 3, ratio: 3.5, index: 2.2, partial: 0.00, length: 0.075)     // mechanical, lowest
        }
    }

    static func of(_ id: String) -> (SoundFamily, Int) {
        for f in SoundFamily.allCases {
            if let i = f.members.firstIndex(of: id) { return (f, i) }
        }
        // A target nobody has given a sound yet: stable pick, so it still always sounds the same.
        let h = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 1000 }
        return (.documents, h % 8)
    }
}

enum SoundProfile {
    /// Targets that throw information away. Judgment call, edit freely.
    static let lossy: Set<String> = ["jpg", "heic", "webp", "gif", "mp3", "m4a", "ogg", "webm", "compress"]
}

// MARK: - Synthesis (pure functions: samples in, samples out)

enum Synth {
    static let rate = 44100.0

    static func midi(step: Int) -> Int {
        let degrees = [0, 2, 4, 7, 9]
        return 48 + degrees[step % 5] + 12 * (step / 5)
    }

    static func frequency(midi: Int) -> Double {
        440.0 * pow(2.0, Double(midi - 69) / 12.0)
    }

    /// One FM chirp. Subtle: a short soft tick. Drone: longer, with an upward glide.
    /// `glide` > 0 starts below the pitch and slides up, < 0 starts above and sags.
    static func chirp(freq: Double, timbre t: Timbre, mode: SoundMode, lossy: Bool = false,
                      lengthScale: Double = 1.0, glide: Double? = nil) -> [Double] {
        let drone = mode == .drone
        let length = t.length * lengthScale * (drone ? 1.0 : 0.55)
        let index0 = t.index * (drone ? 1.0 : 0.8)
        let g = glide ?? (drone ? 0.12 : 0.0)
        let attack = drone ? 0.004 : 0.006
        let tau = length * 0.3
        let count = Int(length * 1.3 * rate)

        var out = [Double](repeating: 0, count: count)
        var carrier = 0.0
        var modulator = 0.0
        for n in 0..<count {
            let x = Double(n) / rate
            let f = freq * (1.0 - g * exp(-x / 0.012))
            carrier += 2.0 * Double.pi * f / rate
            modulator += 2.0 * Double.pi * f * t.ratio / rate
            let depth = index0 * exp(-x / (length * 0.35))
            var s = sin(carrier + depth * sin(modulator))
            s += t.partial * sin(2.0 * carrier)
            let env = min(x / attack, 1.0) * exp(-x / tau)
            out[n] = s * env
        }
        fadeOut(&out, seconds: 0.006)
        if lossy { crush(&out, bits: drone ? 4 : 6, hold: drone ? 3 : 2) }
        return out
    }

    /// Rising scan, like something locking on.
    static func sweep(from f0: Double, to f1: Double, seconds: Double, tremolo: Double, shimmer: Double) -> [Double] {
        let count = Int(seconds * rate)
        var out = [Double](repeating: 0, count: count)
        var p1 = 0.0
        var p2 = 0.0
        for n in 0..<count {
            let x = Double(n) / rate
            let u = x / seconds
            let f = f0 * pow(f1 / f0, u)
            p1 += 2.0 * Double.pi * f / rate
            p2 += 2.0 * Double.pi * f * (1.0 + shimmer) / rate
            let env = pow(sin(Double.pi * u), 1.5)
            let trem = 1.0 - tremolo * (0.5 + 0.5 * sin(2.0 * Double.pi * 24.0 * x))
            var s = sin(p1) + 0.35 * sin(2.0 * p1)
            if shimmer > 0 { s += 0.6 * sin(p2) }
            out[n] = s * env * trem
        }
        fadeOut(&out, seconds: 0.006)
        return out
    }

    /// Muted thud for something that won't work.
    static func blocked(mode: SoundMode) -> [Float] {
        let count = Int(0.07 * 1.4 * rate)
        var out = [Double](repeating: 0, count: count)
        for n in 0..<count {
            let x = Double(n) / rate
            let s = sin(2.0 * Double.pi * 150.0 * x) + 0.3 * sin(2.0 * Double.pi * 300.0 * x)
            out[n] = s * min(x / 0.003, 1.0) * exp(-x / 0.018)
        }
        var y = 0.0
        for i in 0..<count {
            y += 0.25 * (out[i] - y)      // one-pole low-pass: dull
            out[i] = y
        }
        fadeOut(&out, seconds: 0.008)
        return finish(out, peak: mode == .drone ? 0.6 : 0.4)
    }

    static func hover(id: String, mode: SoundMode) -> [Float] {
        let (family, step) = SoundFamily.of(id)
        let t = family.timbre
        let freq = frequency(midi: midi(step: t.baseStep + step))
        var s = chirp(freq: freq, timbre: t, mode: mode, lossy: SoundProfile.lossy.contains(id))
        if mode == .drone { s = echo(s, delay: 0.06, feedback: 0.35, repeats: 2) }
        return finish(s, peak: mode == .drone ? 0.8 : 0.5)
    }

    static func event(_ e: SoundEvent, mode: SoundMode, jitter: Double) -> [Float] {
        let drone = mode == .drone
        var s: [Double]
        switch e {
        case .appear:
            if drone {
                s = sweep(from: 220 * jitter, to: 1760 * jitter, seconds: 0.16, tremolo: 0.3, shimmer: 0.012)
                s = echo(s, delay: 0.07, feedback: 0.35, repeats: 2)
            } else {
                s = sweep(from: 620 * jitter, to: 930 * jitter, seconds: 0.055, tremolo: 0, shimmer: 0)
            }
            return finish(s, peak: drone ? 0.7 : 0.3)

        case .commit:
            // Two tones a fifth apart: question answered.
            let t = Timbre(baseStep: 0, ratio: 2.0, index: 1.2, partial: 0.1, length: 0.07)
            s = chirp(freq: 660 * jitter, timbre: t, mode: mode)
            mix(&s, chirp(freq: 990 * jitter, timbre: t, mode: mode), at: drone ? 0.065 : 0.05)
            if drone { s = echo(s, delay: 0.09, feedback: 0.35, repeats: 2) }
            return finish(s, peak: drone ? 0.8 : 0.5)

        case .done:
            // Rising C major arpeggio, the last note left to ring.
            let t = Timbre(baseStep: 0, ratio: 2.0, index: 1.0, partial: 0.2, length: 0.2)
            let notes: [Double] = drone ? [523.25, 659.25, 783.99, 1046.5] : [523.25, 659.25, 783.99]
            let gap = drone ? 0.075 : 0.06
            s = []
            for (i, f) in notes.enumerated() {
                let last = i == notes.count - 1
                mix(&s, chirp(freq: f * jitter, timbre: t, mode: mode, lengthScale: last ? 1.6 : 1.0),
                    at: Double(i) * gap)
            }
            if drone { s = echo(s, delay: 0.12, feedback: 0.4, repeats: 3) }
            return finish(s, peak: drone ? 0.8 : 0.5)

        case .error:
            // Two descending notes, sagging, soft.
            let t = Timbre(baseStep: 0, ratio: 1.0, index: 0.5, partial: 0.45, length: 0.14)
            s = chirp(freq: 392 * jitter, timbre: t, mode: mode, glide: -0.05)
            mix(&s, chirp(freq: 294 * jitter, timbre: t, mode: mode, lengthScale: 1.4, glide: -0.05),
                at: drone ? 0.09 : 0.07)
            if drone { s = echo(s, delay: 0.08, feedback: 0.3, repeats: 2) }
            return finish(s, peak: drone ? 0.7 : 0.45)
        }
    }

    // MARK: Building blocks

    /// Bit-crush: fewer amplitude steps, held samples. Aliasing is the point.
    static func crush(_ s: inout [Double], bits: Int, hold: Int) {
        let levels = Double(1 << (bits - 1))
        var held = 0.0
        for i in 0..<s.count {
            if i % hold == 0 { held = (s[i] * levels).rounded() / levels }
            s[i] = held
        }
    }

    static func echo(_ s: [Double], delay: Double, feedback: Double, repeats: Int) -> [Double] {
        let d = Int(delay * rate)
        var out = s + [Double](repeating: 0, count: d * repeats)
        for r in 1...repeats {
            let g = pow(feedback, Double(r))
            let offset = d * r
            for i in 0..<s.count { out[i + offset] += s[i] * g }
        }
        return out
    }

    static func mix(_ base: inout [Double], _ add: [Double], at seconds: Double) {
        let offset = Int(seconds * rate)
        if base.count < offset + add.count {
            base += [Double](repeating: 0, count: offset + add.count - base.count)
        }
        for i in 0..<add.count { base[offset + i] += add[i] }
    }

    /// Ramp the end to zero so nothing clicks.
    static func fadeOut(_ s: inout [Double], seconds: Double) {
        let n = min(s.count, Int(seconds * rate))
        guard n > 0 else { return }
        for i in 0..<n {
            s[s.count - 1 - i] *= Double(i) / Double(n)
        }
    }

    /// Scale so the loudest sample sits at `peak`.
    static func finish(_ s: [Double], peak: Double) -> [Float] {
        let loudest = s.map { abs($0) }.max() ?? 0
        let g = loudest > 0 ? peak / loudest : 0
        return s.map { Float($0 * g) }
    }
}

// MARK: - Playback

/// Everything is rendered ahead of time into small buffers, so a hover is one `scheduleBuffer` call:
/// no synthesis on the hot path. Hover chirps rotate through a small pool of voices instead of cutting
/// each other off: cutting a buffer mid-waveform clicks, while a voice that is three hovers old has
/// long since decayed to nothing by the time it gets reused.
final class Sound {
    static let shared = Sound()

    var mode: SoundMode = .subtle {
        didSet { if mode != oldValue { applyMode() } }
    }

    private struct Bank {
        var hover: [String: AVAudioPCMBuffer] = [:]
        var events: [SoundEvent: [AVAudioPCMBuffer]] = [:]
        var blocked: AVAudioPCMBuffer?
        var isEmpty: Bool { hover.isEmpty && events.isEmpty }
    }

    private let format: AVAudioFormat?
    private var engine: AVAudioEngine?          // created on first use, so headless CLI runs never touch audio
    private var hoverNodes: [AVAudioPlayerNode] = []
    private var eventNode: AVAudioPlayerNode?
    private var voice = 0
    private var bank = Bank()
    private var lastHover: TimeInterval = 0
    private var rearm = false

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: Synth.rate, channels: 1)
    }

    // MARK: Public API (main thread)

    /// Spin the engine up early so the first sound isn't late.
    func warmUp() { _ = ensureRunning() }

    func hover(_ id: String) {
        guard ensureRunning() else { return }
        // Segment changes only reach us on change; this just stops a wild flick from machine-gunning.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHover > 0.035 else { return }
        lastHover = now
        fire(bank.hover[id] ?? renderHover(id), on: nextHoverVoice(), interrupt: true)
    }

    /// For a segment that can't work. Waiting on the dimmed-segment UI.
    func blocked() {
        guard ensureRunning() else { return }
        fire(bank.blocked, on: nextHoverVoice(), interrupt: true)
    }

    func play(_ e: SoundEvent) {
        guard ensureRunning() else { return }
        fire((bank.events[e] ?? []).randomElement(), on: eventNode, interrupt: false)
    }

    /// What you hear when you pick a mode in the menu.
    func demo() {
        guard mode != .off else { return }
        let steps: [(Double, () -> Void)] = [
            (0.00, { self.play(.appear) }),
            (0.28, { self.hover("png") }),
            (0.46, { self.hover("jpg") }),
            (0.64, { self.hover("pdf") }),
            (0.90, { self.play(.commit) }),
            (1.25, { self.play(.done) }),
        ]
        for (delay, work) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // MARK: Internals

    private func gain(_ m: SoundMode) -> Float {
        switch m {
        case .off: return 0
        case .subtle: return 0.45
        case .drone: return 0.5
        }
    }

    private func applyMode() {
        rearm = true
        if mode == .off {
            engine?.stop()                  // give the audio device back
            bank = Bank()
            return
        }
        bank = buildBank(for: mode)
        engine?.mainMixerNode.outputVolume = gain(mode)
    }

    private func ensureRunning() -> Bool {
        guard mode != .off, let format = self.format else { return false }

        if engine == nil {
            let e = AVAudioEngine()
            var voices: [AVAudioPlayerNode] = []
            for _ in 0..<3 {
                let h = AVAudioPlayerNode()
                e.attach(h)
                e.connect(h, to: e.mainMixerNode, format: format)
                voices.append(h)
            }
            let v = AVAudioPlayerNode()
            e.attach(v)
            e.connect(v, to: e.mainMixerNode, format: format)
            e.mainMixerNode.outputVolume = gain(mode)
            engine = e
            hoverNodes = voices
            eventNode = v
            // Headphones plugged in, output device switched: the engine stops itself. Bring it back.
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                   object: e, queue: .main) { [weak self] _ in
                guard let self, let eng = self.engine, self.mode != .off else { return }
                self.rearm = true
                if !eng.isRunning { try? eng.start() }
            }
        }

        guard let e = engine else { return false }
        if !e.isRunning {
            do { try e.start() } catch { return false }
            rearm = true
        }
        if bank.isEmpty { bank = buildBank(for: mode) }
        return true
    }

    private func fire(_ buffer: AVAudioPCMBuffer?, on node: AVAudioPlayerNode?, interrupt: Bool) {
        guard let buffer = buffer, let node = node, let e = engine, e.isRunning else { return }
        if rearm {
            for n in hoverNodes { n.stop() }
            eventNode?.stop()
            rearm = false
        }
        if !node.isPlaying { node.play() }
        node.scheduleBuffer(buffer, at: nil, options: interrupt ? .interrupts : [], completionHandler: nil)
    }

    private func nextHoverVoice() -> AVAudioPlayerNode? {
        guard !hoverNodes.isEmpty else { return nil }
        let node = hoverNodes[voice % hoverNodes.count]
        voice += 1
        return node
    }

    private func buildBank(for mode: SoundMode) -> Bank {
        var b = Bank()
        for family in SoundFamily.allCases {
            for id in family.members {
                b.hover[id] = makeBuffer(Synth.hover(id: id, mode: mode))
            }
        }
        for e in SoundEvent.allCases {
            // Three takes with a hair of pitch jitter, so the one-shot sounds don't feel canned.
            var takes: [AVAudioPCMBuffer] = []
            for _ in 0..<3 {
                let jitter = Double.random(in: 0.985...1.015)
                if let buf = makeBuffer(Synth.event(e, mode: mode, jitter: jitter)) { takes.append(buf) }
            }
            b.events[e] = takes
        }
        b.blocked = makeBuffer(Synth.blocked(mode: mode))
        return b
    }

    private func renderHover(_ id: String) -> AVAudioPCMBuffer? {
        let buf = makeBuffer(Synth.hover(id: id, mode: mode))
        bank.hover[id] = buf
        return buf
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = self.format, !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count { channel[i] = samples[i] }
        return buf
    }
}
