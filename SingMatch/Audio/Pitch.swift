import Foundation
import Accelerate

/// YIN fundamental-frequency estimator (de Cheveigné & Kawahara, 2002).
final class YINDetector {
    let sampleRate: Double
    let threshold: Float
    private let tauMin: Int
    private let tauMax: Int
    private var diff: [Float]
    private var cmnd: [Float]

    /// `window` = analysis frame length in samples; correlation length is window/2.
    init(sampleRate: Double, window: Int, fMin: Double = 65, fMax: Double = 1100, threshold: Float = 0.15) {
        self.sampleRate = sampleRate
        self.threshold = threshold
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

/// Turns the isolated vocal track into a list of notes.
enum MelodyExtractor {
    static func extract(left: [Float], right: [Float], sampleRate: Double = 44100,
                        progress: (Double) -> Void = { _ in }) -> [MelodyNote] {
        // Mono, downsampled ×2 (average pairs) → 22.05 kHz
        let n2 = left.count / 2
        guard n2 > 4096 else { return [] }
        var mono = [Float](repeating: 0, count: n2)
        for i in 0..<n2 {
            let j = 2 * i
            mono[i] = 0.25 * (left[j] + left[j + 1] + right[j] + right[j + 1])
        }
        let sr = sampleRate / 2
        let win = 2048, hop = 220
        let dt = Double(hop) / sr
        let frames = (n2 - win) / hop
        guard frames > 10 else { return [] }

        // Loudness gate relative to the vocal's own level
        var levels = [Float](repeating: 0, count: frames)
        mono.withUnsafeBufferPointer { buf in
            for k in 0..<frames { levels[k] = rms(buf.baseAddress! + k * hop, win) }
        }
        let sorted = levels.sorted()
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        let gate = max(0.003, 0.12 * p90)

        let yin = YINDetector(sampleRate: sr, window: win)
        var pitch = [Double](repeating: .nan, count: frames)
        mono.withUnsafeBufferPointer { buf in
            for k in 0..<frames {
                if levels[k] > gate, let hz = yin.detect(buf.baseAddress! + k * hop, window: win) {
                    pitch[k] = NoteName.midi(fromHz: hz)
                }
                if k % 500 == 0 { progress(Double(k) / Double(frames)) }
            }
        }

        // 5-frame median filter over voiced frames
        var smooth = [Double](repeating: .nan, count: frames)
        for k in 0..<frames where !pitch[k].isNaN {
            let lo = max(0, k - 2), hi = min(frames - 1, k + 2)
            let w = pitch[lo...hi].filter { !$0.isNaN }
            if w.count >= 3 { smooth[k] = median(Array(w)) }
        }

        // Segment into notes
        var raw: [(Double, Double, Int)] = []
        var cur: [Double] = []
        var startK = 0, gap = 0
        func flush(_ endK: Int) {
            if Double(cur.count) * dt >= 0.10 {
                raw.append((Double(startK) * dt, Double(endK) * dt, Int(median(cur).rounded())))
            }
        }
        for k in 0..<frames {
            let x = smooth[k]
            if x.isNaN {
                gap += 1
                if !cur.isEmpty && Double(gap) * dt > 0.06 { flush(k - gap + 1); cur = [] }
                continue
            }
            if !cur.isEmpty && abs(x - median(Array(cur.suffix(8)))) > 0.7 {
                flush(k); cur = []
            }
            if cur.isEmpty { startK = k }
            cur.append(x)
            gap = 0
        }
        if !cur.isEmpty { flush(frames) }

        // Merge same-pitch notes separated by tiny gaps
        var merged: [(Double, Double, Int)] = []
        for note in raw {
            if let last = merged.last, last.2 == note.2, note.0 - last.1 < 0.08 {
                merged[merged.count - 1].1 = note.1
            } else {
                merged.append(note)
            }
        }
        // Frame time = window start; shift by half a window so notes line up with the audio
        let offset = Double(win) / 2 / sr
        progress(1)
        return merged.enumerated().map {
            MelodyNote(id: $0.offset, start: $0.element.0 + offset, end: $0.element.1 + offset, midi: $0.element.2)
        }
    }

    static func median(_ a: [Double]) -> Double {
        let s = a.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
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
