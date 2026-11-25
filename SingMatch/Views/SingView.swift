import SwiftUI

struct SingView: View {
    @EnvironmentObject var store: SongStore
    @StateObject private var session: SingSession
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showResult = false

    init(meta: SongMeta, notes: [MelodyNote], contour: GuideContour? = nil) {
        _session = StateObject(wrappedValue: SingSession(meta: meta, notes: notes, contour: contour))
    }

    var body: some View {
        VStack(spacing: 12) {
            readout
            PianoRollView(session: session)
                .frame(minHeight: 260)
                .overlay {
                    if session.updatingMelody {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Updating the melody for this song…").font(.footnote)
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal)
            legend
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
            // Songs added before the improved melody finder get re-analysed once
            if store.needsReanalysis(session.meta.id) {
                session.setUpdatingMelody(true)
                if let result = await store.reanalyse(session.meta) {
                    session.reload(notes: result.notes, contour: result.contour)
                }
                session.setUpdatingMelody(false)
            }
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
                    .foregroundStyle(RollColors.voice)
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

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: 14) {
            if session.reviewing == nil {
                LegendItem(color: .accentColor, label: "Notes", bar: true)
                LegendItem(color: RollColors.guideLine, label: "Singer")
                LegendItem(color: RollColors.voice, label: "You")
                LegendItem(color: RollColors.onNote, label: "On note")
            } else {
                LegendItem(color: .accentColor, label: "Where it should be", bar: true)
                LegendItem(color: RollColors.voice, label: "You sang")
                LegendItem(color: RollColors.corrected, label: "Corrected")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
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

            takePanel

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

extension SingView {
    // MARK: Your take

    var takePanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Your recording").font(.headline)
                    Spacer()
                    if session.takeState == .recording {
                        Label("Recording", systemImage: "record.circle")
                            .font(.caption.bold()).foregroundStyle(.red)
                    }
                }
                Toggle("Record me while I sing", isOn: $session.recordTakes)
                    .disabled(session.isPlaying && session.reviewing == nil)

                switch session.takeState {
                case .processing:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Correcting your recording…").font(.callout)
                    }
                case .failed(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                default:
                    EmptyView()
                }

                if let take = session.take, session.takeState != .processing {
                    Text("Last recording: \(formatTime(take.songStart)) to \(formatTime(take.songEnd)) of the song")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        reviewButton(.mine, title: "Play me", icon: "person.wave.2")
                        reviewButton(.corrected, title: "Play corrected", icon: "wand.and.stars")
                    }
                } else if session.takeState == .none {
                    Text("Sing along, then pause or finish the song. You can play back your singing, and a corrected version moved onto the right notes, to hear and see where each note should be.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reviewButton(_ source: ReviewSource, title: String, icon: String) -> some View {
        let active = session.reviewing == source
        return Button {
            if active { session.stopReview() } else { session.startReview(source) }
        } label: {
            Label(active ? "Stop" : title, systemImage: active ? "stop.fill" : icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(source == .mine ? RollColors.voice : RollColors.corrected)
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    var bar = false
    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: bar ? 14 : 12, height: bar ? 8 : 3)
            Text(label)
        }
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
                .stroke(RollColors.voice, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: denied ? "mic.slash.fill" : "mic.fill")
                .foregroundStyle(denied ? Color.red : RollColors.voice)
        }
        .frame(width: 34, height: 34)
        .animation(.linear(duration: 0.08), value: level)
    }
}
