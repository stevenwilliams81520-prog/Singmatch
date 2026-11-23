import Foundation

/// One note of the extracted vocal melody.
struct MelodyNote: Codable, Hashable, Identifiable {
    var id: Int
    var start: Double   // seconds
    var end: Double     // seconds
    var midi: Int       // MIDI note number (60 = middle C)
}

struct SongMeta: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var duration: Double
    var created: Date
    var noteCount: Int
    var lowMidi: Int
    var highMidi: Int
    var bestScore: Int?
}

enum NoteName {
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    static func name(_ midi: Int) -> String {
        let pc = ((midi % 12) + 12) % 12
        let octave = Int(floor(Double(midi) / 12.0)) - 1
        return names[pc] + String(octave)
    }

    static func name(_ midi: Double) -> String { name(Int(midi.rounded())) }

    static func isBlackKey(_ midi: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(((midi % 12) + 12) % 12)
    }

    static func midi(fromHz hz: Double) -> Double { 69 + 12 * log2(hz / 440) }
}

func formatTime(_ t: Double) -> String {
    let s = max(0, Int(t.rounded()))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// Stores processed songs in Documents/Songs/<id>/ (vocals.m4a, backing.m4a, notes.json).
@MainActor
final class SongStore: ObservableObject {
    @Published private(set) var songs: [SongMeta] = []

    nonisolated static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    nonisolated static func folder(_ id: UUID) -> URL {
        let url = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    nonisolated static func vocalsURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("vocals.m4a") }
    nonisolated static func backingURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("backing.m4a") }
    nonisolated static func notesURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("notes.json") }
    private var indexURL: URL { Self.root.appendingPathComponent("index.json") }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([SongMeta].self, from: data) else { return }
        songs = list.sorted { $0.created > $1.created }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(songs) { try? data.write(to: indexURL, options: .atomic) }
    }

    func add(_ meta: SongMeta) {
        songs.insert(meta, at: 0)
        save()
    }

    func delete(_ meta: SongMeta) {
        songs.removeAll { $0.id == meta.id }
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(meta.id.uuidString))
        save()
    }

    func recordScore(_ score: Int, for id: UUID) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        if (songs[i].bestScore ?? -1) < score {
            songs[i].bestScore = score
            save()
        }
    }

    func notes(for id: UUID) -> [MelodyNote] {
        guard let data = try? Data(contentsOf: Self.notesURL(id)),
              let notes = try? JSONDecoder().decode([MelodyNote].self, from: data) else { return [] }
        return notes
    }
}
