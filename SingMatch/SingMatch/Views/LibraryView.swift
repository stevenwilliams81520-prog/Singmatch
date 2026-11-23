import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var store: SongStore
    @EnvironmentObject var processor: SongProcessor
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if store.songs.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.songs) { song in
                            NavigationLink(value: song) { SongRow(song: song) }
                        }
                        .onDelete { idx in idx.map { store.songs[$0] }.forEach(store.delete) }
                    }
                }
            }
            .navigationTitle("Sing Match")
            .navigationDestination(for: SongMeta.self) { song in
                SingView(meta: song, notes: store.notes(for: song.id))
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showImporter = true } label: { Label("Add song", systemImage: "plus") }
                        .disabled(processor.isBusy)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
                if case .success(let url) = result { processor.start(url: url, store: store) }
            }
            .sheet(isPresented: Binding(get: { processor.stage != .idle }, set: { _ in })) {
                ProcessingView().environmentObject(processor)
                    .interactiveDismissDisabled()
                    .presentationDetents([.medium])
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.mic")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Add a song to get started").font(.title3.bold())
            Text("Pick an audio file (MP3, M4A, WAV…). Sing Match splits the vocals from the music on your phone, writes out the melody as notes, then shows you how closely you're singing along.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button { showImporter = true } label: {
                Label("Choose a song", systemImage: "plus.circle.fill").font(.headline)
            }
            .buttonStyle(.borderedProminent)
            Label("Headphones give the best results", systemImage: "headphones")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct SongRow: View {
    let song: SongMeta
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(song.title).font(.headline).lineLimit(1)
            HStack(spacing: 12) {
                Label(formatTime(song.duration), systemImage: "clock")
                if song.noteCount > 0 {
                    Label("\(NoteName.name(song.lowMidi))–\(NoteName.name(song.highMidi))", systemImage: "music.note")
                }
                if let best = song.bestScore {
                    Label("\(best)%", systemImage: "star.fill").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ProcessingView: View {
    @EnvironmentObject var processor: SongProcessor

    var body: some View {
        VStack(spacing: 20) {
            Text(processor.title).font(.headline).lineLimit(2).multilineTextAlignment(.center)
            switch processor.stage {
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text(msg).multilineTextAlignment(.center)
                Button("OK") { processor.dismissError() }.buttonStyle(.borderedProminent)
            default:
                stepView
                Text("Keep the app open — this runs entirely on your phone and can take a minute or two.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Cancel", role: .cancel) { processor.cancel() }
            }
        }
        .padding(28)
    }

    @ViewBuilder private var stepView: some View {
        switch processor.stage {
        case .downloadingModel(let p):
            step("Downloading vocal model (one time only)", p)
        case .decoding:
            step("Reading song", nil)
        case .separating(let p):
            step("Separating vocals", p)
        case .findingMelody(let p):
            step("Writing out the melody", p)
        case .saving:
            step("Saving", nil)
        default:
            EmptyView()
        }
    }

    private func step(_ label: String, _ p: Double?) -> some View {
        VStack(spacing: 10) {
            if let p {
                ProgressView(value: p) { Text(label) } currentValueLabel: { Text("\(Int(p * 100))%") }
            } else {
                ProgressView(label)
            }
        }
    }
}
