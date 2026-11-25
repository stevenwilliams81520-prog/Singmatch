import Foundation
import AVFoundation

/// A recorded attempt at the song, plus its analysed and corrected pitch lines.
struct TakeInfo: Codable {
    var songStart: Double    // song time (seconds) where the recording begins
    var duration: Double     // length of the recording in seconds
    var hop: Double          // seconds between pitch points
    var offset: Double       // song time of the first pitch point
    var sung: [Int16]        // what was sung: MIDI × 100, or -1 for silence
    var tuned: [Int16]       // where the correction moved it to
    var created: Date

    var songEnd: Double { songStart + duration }

    func sungMidi(at t: Double) -> Double? { value(sung, at: t) }
    func tunedMidi(at t: Double) -> Double? { value(tuned, at: t) }

    private func value(_ a: [Int16], at t: Double) -> Double? {
        let k = Int(((t - offset) / hop).rounded())
        guard k >= 0, k < a.count, a[k] >= 0 else { return nil }
        return Double(a[k]) / 100
    }
}

/// Writes the microphone to a file while the singer is singing.
/// Called from the audio tap thread, so everything is behind a lock.
final class TakeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var mono: AVAudioPCMBuffer?
    private(set) var firstHostTime: UInt64?
    private(set) var frames: AVAudioFramePosition = 0
    private(set) var sampleRate: Double = 0

    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return file != nil }

    func start(url: URL, sampleRate: Double) throws {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 1, interleaved: false)
        self.sampleRate = sampleRate
        firstHostTime = nil
        frames = 0
    }

    /// Takes the first channel of a mic buffer and appends it.
    func write(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        guard let file, let format, let src = buffer.floatChannelData else { return }
        let n = AVAudioFrameCount(buffer.frameLength)
        guard n > 0 else { return }
        if mono == nil || mono!.frameCapacity < n {
            mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(n, 4096))
        }
        guard let mono, let dst = mono.floatChannelData else { return }
        memcpy(dst[0], src[0], Int(n) * MemoryLayout<Float>.size)
        mono.frameLength = n
        if firstHostTime == nil {
            firstHostTime = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
        }
        do {
            try file.write(from: mono)
            frames += AVAudioFramePosition(n)
        } catch {
            self.file = nil
        }
    }

    /// Closes the file. Returns the host time of the first sample and the length in seconds.
    func stop() -> (firstHost: UInt64, seconds: Double)? {
        lock.lock(); defer { lock.unlock() }
        let wasRecording = file != nil
        file = nil            // closing the file finalises the m4a
        guard wasRecording, let first = firstHostTime, sampleRate > 0 else { return nil }
        return (first, Double(frames) / sampleRate)
    }
}

enum TakeError: LocalizedError {
    case unreadable, renderFailed
    var errorDescription: String? {
        switch self {
        case .unreadable: return "Your recording couldn't be read."
        case .renderFailed: return "Your recording couldn't be corrected."
        }
    }
}

/// Works out what was sung, where it should have been, and renders a pitch-corrected copy.
enum TakeProcessor {
    struct Settings {
        var notes: [MelodyNote]       // sorted by start
        var octaveShift: Int
        var anyOctave: Bool
    }

    static func process(takeURL: URL, tunedURL: URL, songStart: Double,
                        settings: Settings) throws -> TakeInfo {
        // Read the recording
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: takeURL) } catch { throw TakeError.unreadable }
        let fmt = file.processingFormat
        let sr = fmt.sampleRate
        let length = AVAudioFrameCount(file.length)
        guard length > AVAudioFrameCount(sr), sr > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: length) else { throw TakeError.unreadable }
        try file.read(into: buf)
        guard let ch = buf.floatChannelData else { throw TakeError.unreadable }
        let n = Int(buf.frameLength)
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))

        // 1. Pitch of the singer, every 10 ms
        let win = sr > 30000 ? 2048 : 1024
        let hop = max(1, Int(sr * 0.01))
        let dt = Double(hop) / sr
        let winOffset = Double(win) / 2 / sr
        let frames = max(0, (n - win) / hop)
        var levels = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { b in
            for k in 0..<frames { levels[k] = rms(b.baseAddress! + k * hop, win) }
        }
        let sortedLevels = levels.sorted()
        let p90 = sortedLevels.isEmpty ? 0 : sortedLevels[min(sortedLevels.count - 1, Int(Double(sortedLevels.count) * 0.9))]
        let gate = max(0.002, 0.1 * p90)
        let yin = YINDetector(sampleRate: sr, window: win, fMin: 70, fMax: 1100,
                              threshold: 0.18, fallbackThreshold: 0.35)
        var sung = [Double](repeating: .nan, count: frames)
        samples.withUnsafeBufferPointer { b in
            for k in 0..<frames where levels[k] > gate {
                if let hz = yin.detect(b.baseAddress! + k * hop, window: win) {
                    sung[k] = NoteName.midi(fromHz: hz)
                }
            }
        }
        PitchCleanup.fixOctaveJumps(&sung, radius: 10)
        PitchCleanup.fillGaps(&sung, maxGap: 3, maxJump: 1.5)
        sung = PitchCleanup.medianSmooth(sung, radius: 2, minCount: 2)

        // 2. Where each moment should have been
        let notes = settings.notes
        func noteIndex(_ t: Double) -> Int? {
            var lo = 0, hi = notes.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if t < notes[mid].start { hi = mid - 1 }
                else if t >= notes[mid].end { lo = mid + 1 }
                else { return mid }
            }
            return nil
        }
        let shiftSemis = Double(12 * settings.octaveShift)
        var rawShift = [Double](repeating: .nan, count: frames)   // cents, NaN when silent
        for k in 0..<frames where !sung[k].isNaN {
            let m = sung[k]
            let t = songStart + Double(k) * dt + winOffset
            var target = m.rounded()          // between notes: nearest semitone
            if let i = noteIndex(t) {
                var want = Double(notes[i].midi) + shiftSemis
                if settings.anyOctave { want += 12 * ((m - want) / 12).rounded() }
                // Way off (or a detection slip): just tidy to the nearest semitone
                if abs(want - m) <= 5 { target = want }
            }
            var cents = (target - m) * 100
            if abs(cents) < 12 { cents = 0 }   // already close: leave the voice natural
            rawShift[k] = cents
        }

        // 3. Smooth the correction so it glides rather than warbles; hold it briefly
        //    through consonants, then let go.
        var shift = [Double](repeating: 0, count: frames)
        var current = 0.0, silentRun = 0
        let attack = 0.35
        for k in 0..<frames {
            if rawShift[k].isNaN {
                silentRun += 1
                if silentRun > 15 { current *= 0.85 }
            } else {
                silentRun = 0
                current += (rawShift[k] - current) * attack
            }
            shift[k] = max(-1200, min(1200, current))
        }

        // 4. Render the corrected copy with Apple's pitch shifter, changing the amount
        //    every 10 ms.
        try render(samples: samples, format: fmt, hop: hop, shiftAt: { frameIndex in
            let k = Int((Double(frameIndex) / Double(hop)).rounded()) - win / 2 / hop
            guard k >= 0 && k < frames else { return 0 }
            return Float(shift[k])
        }, to: tunedURL)

        let toCents: (Double) -> Int16 = { $0.isNaN ? -1 : Int16(max(0, min(12700, ($0 * 100).rounded()))) }
        let tuned: [Int16] = (0..<frames).map { k in
            sung[k].isNaN ? -1 : toCents(sung[k] + shift[k] / 100)
        }
        return TakeInfo(songStart: songStart, duration: Double(n) / sr, hop: dt,
                        offset: songStart + winOffset, sung: sung.map(toCents), tuned: tuned,
                        created: Date())
    }

    private static func render(samples: [Float], format: AVAudioFormat, hop: Int,
                               shiftAt: (Int) -> Float, to url: URL) throws {
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                 channels: 1, interleaved: false)!
        let n = samples.count
        guard let source = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(n)),
              let sch = source.floatChannelData else { throw TakeError.renderFailed }
        source.frameLength = AVAudioFrameCount(n)
        samples.withUnsafeBufferPointer { memcpy(sch[0], $0.baseAddress!, n * MemoryLayout<Float>.size) }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let shifter = AVAudioUnitTimePitch()
        shifter.overlap = 8
        engine.attach(player)
        engine.attach(shifter)
        engine.connect(player, to: shifter, format: mono)
        engine.connect(shifter, to: engine.mainMixerNode, format: mono)
        let block = AVAudioFrameCount(hop)
        try engine.enableManualRenderingMode(.offline, format: mono, maximumFrameCount: max(block, 1024))
        try engine.start()
        player.scheduleBuffer(source, at: nil, options: [], completionHandler: nil)
        player.play()

        // The shifter delays the sound slightly; render that much extra and trim it off the front.
        let latencyFrames = Int((shifter.auAudioUnit.latency * format.sampleRate).rounded())
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let out = try AVAudioFile(forWriting: url, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount),
              let trimmed = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                             frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { throw TakeError.renderFailed }

        let total = n + latencyFrames
        var rendered = 0
        while rendered < total {
            // The amount applies to the audio going into the shifter now
            shifter.pitch = shiftAt(rendered)
            let count = AVAudioFrameCount(min(Int(block), total - rendered))
            let status = try engine.renderOffline(count, to: buffer)
            guard status == .success else {
                if status == .error { throw TakeError.renderFailed }
                break
            }
            let got = Int(buffer.frameLength)
            let skip = max(0, min(got, latencyFrames - rendered))
            if got - skip > 0, let src = buffer.floatChannelData, let dst = trimmed.floatChannelData {
                memcpy(dst[0], src[0] + skip, (got - skip) * MemoryLayout<Float>.size)
                trimmed.frameLength = AVAudioFrameCount(got - skip)
                try out.write(from: trimmed)
            }
            rendered += got
            if got == 0 { break }
        }
        player.stop()
        engine.stop()
    }
}
