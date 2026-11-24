import Foundation
import AVFoundation

enum Difficulty: String, CaseIterable, Identifiable {
    case easy = "Easy", normal = "Normal", hard = "Hard"
    var id: String { rawValue }
    /// Allowed error in semitones (1 semitone = 100 cents)
    var tolerance: Double {
        switch self { case .easy: return 1.0; case .normal: return 0.5; case .hard: return 0.25 }
    }
}

final class WeakSession: @unchecked Sendable {
    weak var value: SingSession?
    init(_ v: SingSession) { value = v }
}

struct TrailPoint {
    var time: Double
    var midi: Double
    var hit: Bool
}

/// Plays the separated backing + guide vocal, listens to the mic and scores the singer.
@MainActor
final class SingSession: ObservableObject {
    let meta: SongMeta
    let notes: [MelodyNote]

    // Playback
    @Published private(set) var isPlaying = false
    @Published private(set) var finished = false
    @Published var vocalVolume: Float = 0.5 { didSet { vocalsPlayer.volume = vocalVolume } }
    @Published var backingVolume: Float = 1.0 { didSet { backingPlayer.volume = backingVolume } }

    // Octave / scoring options
    @Published var octaveShift = 0 { didSet { updateGuidePitch() } }
    @Published var anyOctave = false
    @Published var guideFollowsOctave = false { didSet { updateGuidePitch() } }
    @Published var difficulty: Difficulty = .normal
    @Published var echoCancel = true { didSet { if oldValue != echoCancel { rebuildEngine() } } }

    // Live feedback
    @Published private(set) var userMidi: Double?          // as sung
    @Published private(set) var displayMidi: Double?       // folded if "any octave"
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var score = 0
    @Published private(set) var micDenied = false
    @Published var message: String?

    private(set) var trail: [TrailPoint] = []
    private(set) var noteResults: [Int: (hit: Int, total: Int)] = [:]
    private var hitCount = 0, totalCount = 0
    private var octavePairs: [Double] = []   // user − target(unshifted), for auto octave

    let duration: Double
    private let engine = AVAudioEngine()
    private let vocalsPlayer = AVAudioPlayerNode()
    private let backingPlayer = AVAudioPlayerNode()
    private let guidePitch = AVAudioUnitTimePitch()
    private var vocalsFile: AVAudioFile?
    private var backingFile: AVAudioFile?
    private var tracker: LivePitchTracker?
    private var startOffset: Double = 0
    private var pausedAt: Double = 0
    private var playToken = 0
    private var engineReady = false
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    /// Mic analysis lags the audio slightly (window + buffer)
    private let micLatency = 0.07

    var onFinished: ((Int) -> Void)?

    init(meta: SongMeta, notes: [MelodyNote]) {
        self.meta = meta
        self.notes = notes.sorted { $0.start < $1.start }
        self.duration = meta.duration
        vocalsFile = try? AVAudioFile(forReading: SongStore.vocalsURL(meta.id))
        backingFile = try? AVAudioFile(forReading: SongStore.backingURL(meta.id))
        engine.attach(vocalsPlayer)
        engine.attach(backingPlayer)
        engine.attach(guidePitch)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pause()
                self.engineReady = false
            }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Setup

    func prepare() async {
        let granted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        micDenied = !granted
        if vocalsFile == nil || backingFile == nil {
            message = "This song's audio files are missing. Try importing it again."
        }
        setUpEngine()
    }

    private func setUpEngine() {
        guard let vocalsFile, let backingFile else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)

            let input = engine.inputNode
            if !micDenied {
                try? input.setVoiceProcessingEnabled(echoCancel)
            }
            engine.connect(vocalsPlayer, to: guidePitch, format: vocalsFile.processingFormat)
            engine.connect(guidePitch, to: engine.mainMixerNode, format: vocalsFile.processingFormat)
            engine.connect(backingPlayer, to: engine.mainMixerNode, format: backingFile.processingFormat)
            vocalsPlayer.volume = vocalVolume
            backingPlayer.volume = backingVolume
            updateGuidePitch()

            if !micDenied {
                let format = input.outputFormat(forBus: 0)
                if format.sampleRate > 0 && format.channelCount > 0 {
                    let tracker = LivePitchTracker(sampleRate: format.sampleRate)
                    tracker.onPitch = { [weak self] midi, level in self?.handlePitch(midi, level: level) }
                    self.tracker = tracker
                    input.removeTap(onBus: 0)
                    input.installTap(onBus: 0, bufferSize: 1024, format: format,
                                     block: Self.makeTapBlock(tracker))
                }
            }
            engine.prepare()
            try engine.start()
            engineReady = true
        } catch {
            message = "Audio couldn't start: \(error.localizedDescription)"
        }
    }

    private func rebuildEngine() {
        let wasPlaying = isPlaying
        let t = currentTime
        pause()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        setUpEngine()
        pausedAt = t
        if wasPlaying { play() }
    }

    func tearDown() {
        stopPlayers()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func updateGuidePitch() {
        guidePitch.pitch = guideFollowsOctave ? Float(octaveShift * 1200) : 0
    }

    // MARK: Transport

    var currentTime: Double {
        guard isPlaying,
              let nodeTime = backingPlayer.lastRenderTime,
              let pt = backingPlayer.playerTime(forNodeTime: nodeTime) else { return pausedAt }
        return min(duration, startOffset + max(0, Double(pt.sampleTime) / pt.sampleRate))
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let vocalsFile, let backingFile else { return }
        if !engineReady || !engine.isRunning { setUpEngine() }
        guard engine.isRunning else { return }
        if finished || pausedAt >= duration - 0.25 { restartScores(); pausedAt = 0 }
        finished = false

        let sr = backingFile.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(pausedAt * sr)
        playToken += 1
        let token = playToken
        schedule(vocalsFile, on: vocalsPlayer, from: startFrame, token: nil)
        schedule(backingFile, on: backingPlayer, from: startFrame, token: token)
        startOffset = Double(startFrame) / sr

        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        vocalsPlayer.play(at: start)
        backingPlayer.play(at: start)
        isPlaying = true
    }

    private func schedule(_ file: AVAudioFile, on player: AVAudioPlayerNode,
                          from frame: AVAudioFramePosition, token: Int?) {
        let remaining = file.length - frame
        guard remaining > 0 else { return }
        player.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(remaining),
                               at: nil, completionCallbackType: .dataPlayedBack,
                               completionHandler: Self.makeEndHandler(self, token: token))
    }

    /// Audio-thread callbacks are built outside the main actor so they never assume they run on it.
    nonisolated private static func makeTapBlock(_ tracker: LivePitchTracker) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            tracker.push(Array(UnsafeBufferPointer(start: ch[0], count: n)))
        }
    }

    nonisolated private static func makeEndHandler(_ session: SingSession, token: Int?) -> AVAudioPlayerNodeCompletionHandler {
        let ref = WeakSession(session)
        return { _ in
            guard let token else { return }
            Task { @MainActor in ref.value?.playbackEnded(token: token) }
        }
    }

    private func playbackEnded(token: Int) {
        guard token == playToken, isPlaying else { return }
        pausedAt = duration
        stopPlayers()
        isPlaying = false
        finished = true
        onFinished?(score)
    }

    func pause() {
        guard isPlaying else { return }
        pausedAt = currentTime
        stopPlayers()
        isPlaying = false
    }

    private func stopPlayers() {
        playToken += 1
        vocalsPlayer.stop()
        backingPlayer.stop()
    }

    func seek(to t: Double) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        pausedAt = max(0, min(duration, t))
        trail.removeAll()
        if wasPlaying { play() }
    }

    func restart() {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        pausedAt = 0
        restartScores()
        finished = false
        if wasPlaying { play() }
    }

    private func restartScores() {
        trail.removeAll()
        noteResults.removeAll()
        hitCount = 0; totalCount = 0; score = 0
    }

    // MARK: Notes

    /// Index of the note sounding at time t (unshifted), if any.
    func noteIndex(at t: Double) -> Int? {
        var lo = 0, hi = notes.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let n = notes[mid]
            if t < n.start { hi = mid - 1 }
            else if t >= n.end { lo = mid + 1 }
            else { return mid }
        }
        return nil
    }

    func nextNote(after t: Double) -> MelodyNote? {
        notes.first { $0.start > t }
    }

    func targetMidi(_ note: MelodyNote) -> Int { note.midi + 12 * octaveShift }

    /// Fold a sung pitch into the octave nearest the target, when "any octave" is on.
    private func fold(_ m: Double, toward target: Double) -> Double {
        m + 12 * ((target - m) / 12).rounded()
    }

    // MARK: Mic

    private func handlePitch(_ midi: Double?, level: Float) {
        micLevel = level
        userMidi = midi
        let t = currentTime - micLatency
        let idx = isPlaying ? noteIndex(at: t) : nil
        let target = idx.map { Double(targetMidi(notes[$0])) }

        if let m = midi, let target {
            displayMidi = anyOctave ? fold(m, toward: target) : m
        } else {
            displayMidi = midi
        }

        guard isPlaying else { return }

        var hit = false
        if let idx, let target {
            totalCount += 1
            var r = noteResults[idx] ?? (0, 0)
            r.total += 1
            if let d = displayMidi, abs(d - target) <= difficulty.tolerance {
                hit = true
                hitCount += 1
                r.hit += 1
            }
            noteResults[idx] = r
            score = totalCount > 0 ? Int((Double(hitCount) / Double(totalCount) * 100).rounded()) : 0
            if let m = midi { octavePairs.append(m - Double(notes[idx].midi)) }
            if octavePairs.count > 600 { octavePairs.removeFirst(octavePairs.count - 600) }
        }
        if let d = displayMidi {
            trail.append(TrailPoint(time: t, midi: d, hit: hit))
            if trail.count > 800 { trail.removeFirst(trail.count - 800) }
        }
    }

    /// Picks the octave shift that best matches how the user has been singing.
    /// Returns false if there isn't enough singing yet.
    @discardableResult
    func autoOctave() -> Bool {
        guard octavePairs.count >= 40 else {
            message = "Sing along for a few seconds first, then tap Auto."
            return false
        }
        let diff = MelodyExtractor.median(octavePairs)
        octaveShift = max(-3, min(3, Int((diff / 12).rounded())))
        message = nil
        return true
    }

    /// Human-readable label for an octave shift.
    static func label(forShift s: Int) -> String {
        switch s {
        case 0: return "Original"
        case ..<0: return "\(s) octave\(s == -1 ? "" : "s") (deeper)"
        default: return "+\(s) octave\(s == 1 ? "" : "s") (higher)"
        }
    }
}
