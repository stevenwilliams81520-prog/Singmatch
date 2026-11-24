import Foundation
import UIKit

/// Thread-safe cancel flag shared with the background work.
final class CancelFlag {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

/// Import pipeline: decode → separate vocals → extract melody → save.
@MainActor
final class SongProcessor: ObservableObject {
    enum Stage: Equatable {
        case idle
        case decoding
        case separating(Double)
        case findingMelody(Double)
        case saving
        case failed(String)
    }

    @Published var stage: Stage = .idle
    @Published var title = ""
    private var flag = CancelFlag()
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch stage { case .idle, .failed: return false; default: return true }
    }

    func start(url: URL, store: SongStore) {
        guard !isBusy else { return }
        title = url.deletingPathExtension().lastPathComponent
        stage = .decoding

        // Copy out of the Files sandbox first
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "audio" : url.pathExtension)
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            try FileManager.default.copyItem(at: url, to: local)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            stage = .failed("Couldn't read that file: \(error.localizedDescription)")
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }

        let flag = CancelFlag()
        self.flag = flag
        let title = self.title
        UIApplication.shared.isIdleTimerDisabled = true

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let modelURL = try ModelProvider.ensureModel()
                if flag.isCancelled { throw CancellationError() }
                await MainActor.run { self.stage = .decoding }

                let meta = try await Task.detached(priority: .userInitiated) { () throws -> SongMeta in
                    var audio = try AudioIO.decode(url: local)
                    try? FileManager.default.removeItem(at: local)
                    if flag.isCancelled { throw CancellationError() }

                    let separator = try VocalSeparator(modelURL: modelURL)
                    var lastReported = -1.0
                    let vocals = try separator.separate(left: audio.left, right: audio.right, progress: { p in
                        if p - lastReported >= 0.01 || p >= 1 {
                            lastReported = p
                            Task { @MainActor in self.stage = .separating(p) }
                        }
                    }, isCancelled: { flag.isCancelled })

                    Task { @MainActor in self.stage = .findingMelody(0) }
                    let notes = MelodyExtractor.extract(left: vocals.left, right: vocals.right) { p in
                        Task { @MainActor in self.stage = .findingMelody(p) }
                    }
                    if flag.isCancelled { throw CancellationError() }

                    Task { @MainActor in self.stage = .saving }
                    // Backing = original mix minus vocals (in place to save memory)
                    for i in 0..<audio.left.count {
                        audio.left[i] -= vocals.left[i]
                        audio.right[i] -= vocals.right[i]
                    }
                    let id = UUID()
                    try AudioIO.writeM4A(left: vocals.left, right: vocals.right, to: SongStore.vocalsURL(id))
                    try AudioIO.writeM4A(left: audio.left, right: audio.right, to: SongStore.backingURL(id))
                    try JSONEncoder().encode(notes).write(to: SongStore.notesURL(id), options: .atomic)

                    let meta = SongMeta(id: id, title: title,
                                        duration: Double(audio.left.count) / AudioIO.sampleRate,
                                        created: Date(), noteCount: notes.count,
                                        lowMidi: notes.map(\.midi).min() ?? 57,
                                        highMidi: notes.map(\.midi).max() ?? 69,
                                        bestScore: nil)
                    return meta
                }.value

                await MainActor.run {
                    store.add(meta)
                    self.stage = .idle
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: local)
                await MainActor.run {
                    self.stage = .idle
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            } catch {
                try? FileManager.default.removeItem(at: local)
                await MainActor.run {
                    self.stage = .failed(error.localizedDescription)
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
        }
    }

    func cancel() {
        flag.cancel()
    }

    func dismissError() {
        if case .failed = stage { stage = .idle }
    }
}
