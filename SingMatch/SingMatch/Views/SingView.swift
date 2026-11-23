import SwiftUI

struct SingView: View {
    @EnvironmentObject var store: SongStore
    @StateObject private var session: SingSession
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showResult = false

    init(meta: SongMeta, notes: [MelodyNote]) {
        _session = StateObject(wrappedValue: SingSession(meta: meta, notes: notes))
    }

    var body: some View {
        VStack(spacing: 12) {
            readout
            PianoRollView(session: session)
                .frame(minHeight: 260)
                .padding(.horizontal)
            transport
            ScrollView { controls.padding(.horizontal) }
        }
        .navigationTitle(session.meta.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            session.onFinished = { score in
                store.recordScore(score, for: session.meta.id)
                showResult = true
            }
            await session.prepare()
        }
        .onDisappear { session.tearDown() }
        .alert("Song finished", isPresented: $showResult) {
            Button("Sing again") { session.restart(); session.play() }
            Button("Done", role: .cancel) {}
        } message: {
            Text("You scored \(session.score)%.")
        }
    }

    // MARK: Readout

    private var readout: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in readoutContent }
    }

    private var readoutContent: some View {
        let t = session.currentTime
        let idx = session.noteIndex(at: t)
        let target: Int? = idx.map { session.targetMidi(session.notes[$0]) }
        let upcoming = session.nextNote(after: t).map { session.targetMidi($0) }
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TARGET").font(.caption2).foregroundStyle(.secondary)
                Text(target.map { NoteName.name($0) } ?? (upcoming.map { "next \(NoteName.name($0))" } ?? "—"))
                    .font(.title2.monospacedDigit().bold())
            }
            Spacer()
            VStack(spacing: 2) {
                Text("YOU").font(.caption2).foregroundStyle(.secondary)
                Text(session.displayMidi.map { NoteName.name($0) } ?? "—")
                    .font(.title2.monospacedDigit().bold())
                    .foregroundStyle(.pink)
                if let d = session.displayMidi, let target {
                    let cents = Int(((d - Double(target)) * 100).rounded())
                    Text(cents == 0 ? "spot on" : (cents > 0 ? "+\(cents)¢ sharp" : "\(cents)¢ flat"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(abs(cents) <= Int(session.difficulty.tolerance * 100) ? Color.green : Color.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("SCORE").font(.caption2).foregroundStyle(.secondary)
                Text("\(session.score)%").font(.title2.monospacedDigit().bold())
            }
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    // MARK: Transport

    private var transport: some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let now = session.currentTime
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { scrubbing ? scrubValue : now },
                                          set: { scrubValue = $0 }),
                           in: 0...max(1, session.duration),
                           onEditingChanged: { editing in
                               if editing { scrubValue = now; scrubbing = true }
                               else { scrubbing = false; session.seek(to: scrubValue) }
                           })
                    HStack {
                        Text(formatTime(scrubbing ? scrubValue : now))
                        Spacer()
                        Text(formatTime(session.duration))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 40) {
                Button { session.restart() } label: {
                    Image(systemName: "backward.end.fill").font(.title2)
                }
                Button { session.togglePlay() } label: {
                    Image(systemName: session.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }
                MicMeter(level: session.micLevel, denied: session.micDenied)
            }
        }
        .padding(.horizontal)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let msg = session.message {
                Label(msg, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if session.micDenied {
                Label("Microphone access is off. Turn it on in Settings › Sing Match to be scored.",
                      systemImage: "mic.slash").font(.callout).foregroundStyle(.red)
            }
            if session.notes.isEmpty {
                Label("No clear vocal melody was found in this song.", systemImage: "waveform.slash")
                    .font(.callout).foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Octave").font(.headline)
                        Spacer()
                        Button("Auto") { session.autoOctave() }
                            .buttonStyle(.bordered)
                    }
                    HStack {
                        Button { session.octaveShift = max(-3, session.octaveShift - 1) } label: {
                            Label("Deeper", systemImage: "arrow.down.circle.fill")
                        }
                        .disabled(session.octaveShift <= -3)
                        Spacer()
                        Text(SingSession.label(forShift: session.octaveShift))
                            .font(.subheadline.bold()).multilineTextAlignment(.center)
                        Spacer()
                        Button { session.octaveShift = min(3, session.octaveShift + 1) } label: {
                            Label("Higher", systemImage: "arrow.up.circle.fill")
                        }
                        .disabled(session.octaveShift >= 3)
                    }
                    .labelStyle(.titleAndIcon)
                    Text("Moves the notes you're aiming for up or down an octave, so deeper and higher voices can sing the same tune in their own range. Tap Auto after singing a few lines to pick it for you.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Any octave counts", isOn: $session.anyOctave)
                    Toggle("Shift the guide vocal too", isOn: $session.guideFollowsOctave)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Mix").font(.headline)
                    LabeledSlider(title: "Guide vocal", systemImage: "person.wave.2", value: $session.vocalVolume)
                    LabeledSlider(title: "Music", systemImage: "music.note", value: $session.backingVolume)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Scoring").font(.headline)
                    Picker("Difficulty", selection: $session.difficulty) {
                        ForEach(Difficulty.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Echo cancelling (for phone speaker)", isOn: $session.echoCancel)
                    Text("Headphones work best. Without them, keep echo cancelling on so the phone doesn't score the guide vocal instead of you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 24)
    }
}

struct LabeledSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Float
    var body: some View {
        HStack {
            Label(title, systemImage: systemImage).frame(width: 140, alignment: .leading)
            Slider(value: $value, in: 0...1)
        }
        .font(.subheadline)
    }
}

struct MicMeter: View {
    let level: Float
    let denied: Bool
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, Double(level) * 12)))
                .stroke(Color.pink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: denied ? "mic.slash.fill" : "mic.fill")
                .foregroundStyle(denied ? Color.red : Color.pink)
        }
        .frame(width: 34, height: 34)
        .animation(.linear(duration: 0.08), value: level)
    }
}
