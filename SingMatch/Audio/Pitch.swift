import Foundation
import Accelerate

/// YIN fundamental-frequency estimator (de Cheveigné & Kawahara, 2002).
final class YINDetector {
    let sampleRate: Double
    let threshold: Float
    /// If no lag passes `threshold`, accept the deepest dip when it is below this (0 = off).
    let fallbackThreshold: Float
    private let tauMin: Int
    private let tauMax: Int
    private var diff: [Float]
    private var cmnd: [Float]

    /// `window` = analysis frame length in samples; correlation length is window/2.
    init(sampleRate: Double, window: Int, fMin: Double = 65, fMax: Double = 1100,
         threshold: Float = 0.15, fallbackThreshold: Float = 0) {
        self.sampleRate = sampleRate
        self.threshold = threshold
        self.fallbackThreshold = fallbackThreshold
        tauMin = max(2, Int(sampleRate / fMax))
        tauMax = min(Int(sampleRate / fMin), window / 2 - 1)
        diff = [Float](repeating: 0, count: tauMax + 2)
        cmnd = [Float](repeating: 1, count: tauMax + 2)
    }

    /// Returns frequency in Hz, or nil when unvoiced. `p` must hold `window` samples.
    func detect(_ p: UnsafePointer<Float>, window: Int) -> Double? {
        let w = window / 2
        guard tauMax > tauMin + 2 else { return nil }
        for tau in 1...tauMax {
            var r: Float = 0
            vDSP_distancesq(p, 1, p + tau, 1, &r, vDSP_Length(w))
            diff[tau] = r
        }
        cmnd[0] = 1
        var running: Float = 0
        for tau in 1...tauMax {
            running += diff[tau]
            cmnd[tau] = running > 0 ? diff[tau] * Float(tau) / running : 1
        }
        var tau = tauMin
        var found = -1
        while tau <= tauMax {
            if cmnd[tau] < threshold {
                while tau + 1 <= tauMax && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                found = tau
                break
            }
            tau += 1
        }
        if found < 0 && fallbackThreshold > 0 {
            var best = tauMin
            for k in tauMin...tauMax where cmnd[k] < cmnd[best] { best = k }
            if cmnd[best] < fallbackThreshold { found = best }
        }
        guard found > 0 else { return nil }
        var better = Double(found)
        if found > 1 && found < tauMax {
            let s0 = Double(cmnd[found - 1]), s1 = Double(cmnd[found]), s2 = Double(cmnd[found + 1])
            let den = s0 + s2 - 2 * s1
            if abs(den) > 1e-12 { better += (s0 - s2) / (2 * den) }
        }
        return better > 0 ? sampleRate / better : nil
    }
}

func rms(_ p: UnsafePointer<Float>, _ n: Int) -> Float {
    var r: Float = 0
    vDSP_rmsqv(p, 1, &r, vDSP_Length(n))
    return r
}

/// Continuous pitch line of the guide vocal, so every sung moment can be drawn,
/// including slides and short notes that don't become note bars.
struct GuideContour: Codable {
    var hop: Double          // seconds between points
    var offset: Double       // time of the first point
    var cents: [Int16]       // MIDI × 100, or -1 where nobody is singing

    func midi(at t: Double) -> Double? {
        let k = Int(((t - offset) / hop).rounded())
        guard k >= 0, k < cents.count, cents[k] >= 0 else { return nil }
        return Double(cents[k]) / 100
    }
}

struct MelodyAnalysis {
    var notes: [MelodyNote]
    var contour: GuideContour
}

/// Turns the isolated vocal track into a list of notes plus a continuous pitch line.
enum MelodyExtractor {
    static func extract(left: [Float], right: [Float], sampleRate: Double = 44100,
                        progress: (Double) -> Void = { _ in }) -> [MelodyNote] {
        analyse(left: left, right: right, sampleRate: sampleRate, progress: progress).notes
    }

    static func analyse(left: [Float], right: [Float], sampleRate: Double = 44100,
                        progress: (Double) -> Void = { _ in }) -> MelodyAnalysis {
        // Mono, downsampled ×2 (average pairs) → 22.05 kHz
        let n2 = min(left.count, right.count) / 2
        let sr = sampleRate / 2
        let win = 2048, hop = 220
        let dt = Double(hop) / sr
        let offset = Double(win) / 2 / sr
        let empty = MelodyAnalysis(notes: [], contour: GuideContour(hop: dt, offset: offset, cents: []))
        guard n2 > 4096 else { return empty }
        var mono = [Float](repeating: 0, count: n2)
        for i in 0..<n2 {
            let j = 2 * i
            mono[i] = 0.25 * (left[j] + left[j + 1] + right[j] + right[j + 1])
        }
        let frames = (n2 - win) / hop
        guard frames > 10 else { return empty }

        // Loudness gate relative to the vocal's own level (separated vocals have a lot of
        // quiet-but-real singing, so this is gentler than a plain noise gate)
        var levels = [Float](repeating: 0, count: frames)
        mono.withUnsafeBufferPointer { buf in
            for k in 0..<frames { levels[k] = rms(buf.baseAddress! + k * hop, win) }
        }
        let sorted = levels.sorted()
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        let gate = max(0.002, 0.07 * p90)

        // Separated vocals are slightly noisy, so the strict YIN threshold misses a lot of
        // real singing; accept the clearest pitch when it's still reasonably confident.
        let yin = YINDetector(sampleRate: sr, window: win, fMin: 70, fMax: 1100,
                              threshold: 0.2, fallbackThreshold: 0.4)
        var pitch = [Double](repeating: .nan, count: frames)
        mono.withUnsafeBufferPointer { buf in
            for k in 0..<frames {
                if levels[k] > gate, let hz = yin.detect(buf.baseAddress! + k * hop, window: win) {
                    pitch[k] = NoteName.midi(fromHz: hz)
                }
                if k % 500 == 0 { progress(Double(k) / Double(frames)) }
            }
        }

        PitchCleanup.fixOctaveJumps(&pitch, radius: 12)
        PitchCleanup.fillGaps(&pitch, maxGap: 5, maxJump: 2.0)
        let smooth = PitchCleanup.medianSmooth(pitch, radius: 2, minCount: 2)

        let notes = segment(smooth, dt: dt, offset: offset)
        let cents: [Int16] = smooth.map { $0.isNaN ? -1 : Int16(max(0, min(12700, ($0 * 100).rounded()))) }
        progress(1)
        return MelodyAnalysis(notes: notes, contour: GuideContour(hop: dt, offset: offset, cents: cents))
    }

    /// Splits a cleaned pitch line into notes. A new note starts only when the pitch
    /// stays away from the current note for a few frames, so vibrato and scoops don't
    /// chop a note into pieces that are too short to keep.
    static func segment(_ s: [Double], dt: Double, offset: Double) -> [MelodyNote] {
        var segs: [(start: Int, end: Int, midi: Int)] = []
        var cur: [Double] = []
        var startK = 0, gap = 0, devRun = 0
        let maxGapFrames = Int((0.10 / dt).rounded())

        func close(_ endK: Int) {
            if cur.count >= 2 { segs.append((startK, endK, Int(median(cur).rounded()))) }
            cur = []
            devRun = 0
        }

        for k in 0..<s.count {
            let x = s[k]
            if x.isNaN {
                gap += 1
                if !cur.isEmpty && gap > maxGapFrames { close(k - gap + 1) }
                continue
            }
            if !cur.isEmpty {
                let ref = median(Array(cur.suffix(12)))
                devRun = abs(x - ref) > 0.75 ? devRun + 1 : 0
                if devRun >= 3 && cur.count > 2 {
                    let moved = Array(cur.suffix(2))
                    cur.removeLast(2)
                    let split = k - 2
                    close(split)
                    cur = moved
                    startK = split
                }
            }
            if cur.isEmpty { startK = k }
            cur.append(x)
            gap = 0
        }
        if !cur.isEmpty { close(s.count) }

        // Drop only true blips; join same-pitch notes split by short gaps
        var merged: [(start: Int, end: Int, midi: Int)] = []
        for seg in segs where Double(seg.end - seg.start) * dt >= 0.05 {
            if let last = merged.last, last.midi == seg.midi, Double(seg.start - last.end) * dt < 0.12 {
                merged[merged.count - 1].end = seg.end
            } else {
                merged.append(seg)
            }
        }
        return merged.enumerated().map {
            MelodyNote(id: $0.offset,
                       start: Double($0.element.start) * dt + offset,
                       end: Double($0.element.end) * dt + offset,
                       midi: $0.element.midi)
        }
    }

    static func median(_ a: [Double]) -> Double {
        let s = a.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }
}

/// Shared clean-up steps for pitch lines (guide vocal and recorded takes).
enum PitchCleanup {
    /// Pitch trackers sometimes jump an octave for a frame or two; pull those back.
    static func fixOctaveJumps(_ p: inout [Double], radius: Int) {
        let n = p.count
        guard n > 2 else { return }
        let original = p
        for k in 0..<n where !original[k].isNaN {
            let lo = max(0, k - radius), hi = min(n - 1, k + radius)
            let around = original[lo...hi].filter { !$0.isNaN }
            guard around.count >= 5 else { continue }
            let m = MelodyExtractor.median(Array(around))
            let d = original[k] - m
            if abs(d - 12) < 1.5 { p[k] = original[k] - 12 }
            else if abs(d + 12) < 1.5 { p[k] = original[k] + 12 }
        }
    }

    /// Bridges short dropouts (a consonant, a breathy moment) inside a sung line.
    static func fillGaps(_ p: inout [Double], maxGap: Int, maxJump: Double) {
        let n = p.count
        var k = 0
        while k < n {
            guard p[k].isNaN else { k += 1; continue }
            var e = k
            while e < n && p[e].isNaN { e += 1 }
            let len = e - k
            if k > 0, e < n, len <= maxGap, abs(p[e] - p[k - 1]) <= maxJump {
                let a = p[k - 1], b = p[e]
                for i in 0..<len { p[k + i] = a + (b - a) * Double(i + 1) / Double(len + 1) }
            }
            k = e
        }
    }

    static func medianSmooth(_ p: [Double], radius: Int, minCount: Int) -> [Double] {
        let n = p.count
        var out = [Double](repeating: .nan, count: n)
        for k in 0..<n where !p[k].isNaN {
            let lo = max(0, k - radius), hi = min(n - 1, k + radius)
            let w = p[lo...hi].filter { !$0.isNaN }
            if w.count >= minCount { out[k] = MelodyExtractor.median(Array(w)) }
        }
        return out
    }
}

/// Real-time microphone pitch tracking. Feed it raw mic samples from an audio tap.
final class LivePitchTracker {
    private let queue = DispatchQueue(label: "singmatch.pitch", qos: .userInteractive)
    private let window: Int
    private let hop: Int
    private let yin: YINDetector
    private var ring: [Float] = []
    private var sinceLast = 0
    private var history: [Double] = []
    var gate: Float = 0.004
    /// Called on the main queue with MIDI pitch (nil = silence) and level.
    var onPitch: ((Double?, Float) -> Void)?

    init(sampleRate: Double) {
        // ~85 ms analysis window, ~21 ms hop
        window = sampleRate > 30000 ? 4096 : 2048
        hop = window / 4
        yin = YINDetector(sampleRate: sampleRate, window: window, fMin: 60, fMax: 1200, threshold: 0.15)
    }

    func push(_ samples: [Float]) {
        queue.async { [weak self] in self?.process(samples) }
    }

    private func process(_ samples: [Float]) {
        ring.append(contentsOf: samples)
        sinceLast += samples.count
        if ring.count > window * 2 { ring.removeFirst(ring.count - window * 2) }
        while sinceLast >= hop && ring.count >= window {
            sinceLast -= hop
            let start = ring.count - window - max(0, sinceLast)
            guard start >= 0 else { continue }
            var result: Double?
            var level: Float = 0
            ring.withUnsafeBufferPointer { buf in
                let p = buf.baseAddress! + start
                level = rms(p, window)
                if level > gate, let hz = yin.detect(p, window: window) {
                    result = NoteName.midi(fromHz: hz)
                }
            }
            // light smoothing: median of last 3 voiced readings, reset on silence
            if let r = result {
                history.append(r)
                if history.count > 3 { history.removeFirst() }
                result = MelodyExtractor.median(history)
            } else {
                history.removeAll()
            }
            let out = result, lvl = level
            DispatchQueue.main.async { [weak self] in self?.onPitch?(out, lvl) }
        }
    }
}
