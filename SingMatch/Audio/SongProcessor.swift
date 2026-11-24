import Foundation
import UIKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
        case loadingVideo
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

    /// Video chosen from the Photos library.
    func start(photoItem: PhotosPickerItem, store: SongStore) {
        guard !isBusy else { return }
        let photoTitle = "Video \(Date().formatted(date: .abbreviated, time: .shortened))"
        title = photoTitle
        stage = .loadingVideo
        task = Task { [weak self] in
            do {
                guard let movie = try await photoItem.loadTransferable(type: PickedMovie.self) else {
                    throw AudioIOError.unreadable
                }
                guard let self else { return }
                self.start(url: movie.url, store: store, title: photoTitle, isTemporary: true)
            } catch {
                self?.stage = .failed("Couldn't load that video: \(error.localizedDescription)")
            }
        }
    }

    func start(url: URL, store: SongStore, title customTitle: String? = nil, isTemporary: Bool = false) {
        guard !isBusy || stage == .loadingVideo else { return }
        title = customTitle ?? url.deletingPathExtension().lastPathComponent
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
        if isTemporary { try? FileManager.default.removeItem(at: url) }

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

                let meta = try await Task.detached(priority: .userInitiated) { () async throws -> SongMeta in
                    var audio = try await AudioIO.decodeAny(url: local)
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

/// Lets the Photos picker hand over a video as a file we can read.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}
