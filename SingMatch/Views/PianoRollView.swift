import SwiftUI

/// Scrolling note lane: target notes move right→left past a playhead,
/// with the singer's live pitch drawn as a trail.
struct PianoRollView: View {
    @ObservedObject var session: SingSession
    var secondsBehind: Double = 1.5
    var secondsAhead: Double = 4.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !session.isPlaying)) { _ in
            Canvas { ctx, size in draw(ctx, size: size, now: session.currentTime) }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func range() -> (lo: Int, hi: Int) {
        let shift = 12 * session.octaveShift
        var lo = session.meta.lowMidi + shift - 3
        var hi = session.meta.highMidi + shift + 3
        if hi - lo < 14 {
            let mid = (lo + hi) / 2
            lo = mid - 7; hi = mid + 7
        }
        return (lo, hi)
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, now: Double) {
        let labelW: CGFloat = 38
        let rollW = size.width - labelW
        let playheadX = labelW + rollW * CGFloat(secondsBehind / (secondsBehind + secondsAhead))
        let pxPerSec = rollW / CGFloat(secondsBehind + secondsAhead)
        let (lo, hi) = range()
        let rows = CGFloat(hi - lo + 1)
        let rowH = size.height / rows

        func y(_ midi: Double) -> CGFloat {
            size.height - (CGFloat(midi - Double(lo)) + 0.5) * rowH
        }
        func x(_ t: Double) -> CGFloat { playheadX + CGFloat(t - now) * pxPerSec }

        // Lanes + labels
        for m in lo...hi {
            let rect = CGRect(x: labelW, y: y(Double(m)) - rowH / 2, width: rollW, height: rowH)
            if NoteName.isBlackKey(m) {
                ctx.fill(Path(rect), with: .color(.primary.opacity(0.05)))
            }
            if m % 12 == 0 {
                var line = Path()
                line.move(to: CGPoint(x: labelW, y: rect.maxY))
                line.addLine(to: CGPoint(x: size.width, y: rect.maxY))
                ctx.stroke(line, with: .color(.primary.opacity(0.18)), lineWidth: 1)
            }
            if rowH >= 11 || m % 12 == 0 {
                let isC = m % 12 == 0
                ctx.draw(Text(NoteName.name(m))
                            .font(.system(size: min(11, rowH * 0.8), weight: isC ? .bold : .regular))
                            .foregroundColor(.secondary),
                         at: CGPoint(x: labelW / 2, y: y(Double(m))))
            }
        }

        // Target notes
        let shift = 12 * session.octaveShift
        let tStart = now - secondsBehind - 0.5, tEnd = now + secondsAhead + 0.5
        let active = session.noteIndex(at: now)
        for (i, note) in session.notes.enumerated() where note.end > tStart && note.start < tEnd {
            let m = Double(note.midi + shift)
            let rect = CGRect(x: x(note.start), y: y(m) - rowH * 0.42,
                              width: max(3, CGFloat(note.end - note.start) * pxPerSec), height: rowH * 0.84)
            let color: Color
            if i == active {
                color = .yellow
            } else if note.end < now, let r = session.noteResults[i], r.total > 0 {
                let ratio = Double(r.hit) / Double(r.total)
                color = ratio > 0.6 ? .green : (ratio > 0.25 ? .orange : .red)
            } else if note.end < now {
                color = .gray
            } else {
                color = .accentColor
            }
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(6, rect.height / 2)), with: .color(color.opacity(0.85)))
            if rect.width > 30 && rowH >= 12 {
                ctx.draw(Text(NoteName.name(note.midi + shift))
                            .font(.system(size: min(11, rowH * 0.6), weight: .semibold))
                            .foregroundColor(.white),
                         at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
            }
        }

        // Playhead
        var ph = Path()
        ph.move(to: CGPoint(x: playheadX, y: 0))
        ph.addLine(to: CGPoint(x: playheadX, y: size.height))
        ctx.stroke(ph, with: .color(.primary.opacity(0.5)), lineWidth: 2)

        // Singer trail
        for p in session.trail where p.time > tStart && p.time <= now {
            let clamped = min(Double(hi) + 0.4, max(Double(lo) - 0.4, p.midi))
            let c = CGPoint(x: x(p.time), y: y(clamped))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)),
                     with: .color(p.hit ? .green : .pink))
        }

        // Current sung pitch marker
        if let m = session.displayMidi {
            let clamped = min(Double(hi) + 0.4, max(Double(lo) - 0.4, m))
            let c = CGPoint(x: playheadX, y: y(clamped))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(.pink))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)),
                       with: .color(.white), lineWidth: 2)
            if m > Double(hi) + 0.5 || m < Double(lo) - 0.5 {
                ctx.draw(Text(m > Double(hi) ? "▲" : "▼").font(.caption).foregroundColor(.pink),
                         at: CGPoint(x: c.x + 14, y: c.y))
            }
        }
    }
}
