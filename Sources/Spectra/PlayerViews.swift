import SwiftUI

/// Transport controls for whatever Spotify / Music is playing. Shown along the
/// bottom while the mouse is over the window.
struct PlayerBar: View {
    @ObservedObject var player: NowPlaying
    @ObservedObject var state: AppState
    let track: Track
    @State private var dragValue: Double?

    var body: some View {
        HStack(spacing: 14) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            .frame(minWidth: 80, maxWidth: 200, alignment: .leading)

            HStack(spacing: 2) {
                control("backward.fill", size: 13, help: "Previous song ( [ )") { player.previousTrack() }
                control(player.isPlaying ? "pause.fill" : "play.fill", size: 19, help: "Play / pause (Space)") { player.playPause() }
                control("forward.fill", size: 13, help: "Next song ( ] )") { player.nextTrack() }
            }

            if track.duration > 0 {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let position = dragValue ?? player.position
                    HStack(spacing: 8) {
                        Text(Self.clock(position))
                        Slider(value: Binding(get: { position }, set: { dragValue = $0 }),
                               in: 0...max(1, track.duration)) { editing in
                            if !editing, let target = dragValue {
                                player.seek(to: target)
                                dragValue = nil
                            }
                        }
                        .controlSize(.small)
                        Text(Self.clock(track.duration))
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                }
                .frame(minWidth: 160)
            } else {
                Spacer(minLength: 0)
            }

            Button {
                state.settings.karaoke.toggle()
            } label: {
                Image(systemName: state.settings.karaoke ? "music.mic.circle.fill" : "music.mic.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(state.settings.karaoke ? Color.white : Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Karaoke lyrics (K)")
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var cover: some View {
        if let artwork = player.artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.1))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6)))
        }
    }

    private func control(_ symbol: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The karaoke layer: big lyrics in the middle of the picture, the current line
/// filling in as it is sung.
struct KaraokeView: View {
    @ObservedObject var player: NowPlaying
    @ObservedObject var lyrics: Lyrics
    /// Seconds to shift the lyrics by; positive shows them earlier.
    let offset: Double

    var body: some View {
        GeometryReader { geo in
            let fontSize = min(64, max(20, geo.size.width * 0.042))
            Group {
                switch lyrics.state {
                case .synced(let lines):
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                        // Shown a touch ahead of the voice, which is how lyrics read best.
                        SyncedLyrics(lines: lines, position: player.position + offset + 0.1, fontSize: fontSize)
                    }
                case .loading:
                    note("Finding lyrics…", fontSize)
                case .instrumental:
                    note("♪  Instrumental", fontSize)
                case .unavailable:
                    note("No synced lyrics found for this song", fontSize)
                case .idle:
                    EmptyView()
                }
            }
            .padding(.horizontal, geo.size.width * 0.07)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }

    private func note(_ text: String, _ fontSize: CGFloat) -> some View {
        Text(text)
            .font(.system(size: fontSize * 0.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
            .shadow(color: .black.opacity(0.8), radius: 5, y: 1)
    }
}

struct SyncedLyrics: View {
    let lines: [LyricLine]
    let position: Double
    let fontSize: CGFloat

    /// Index of the line being sung; -1 before the first one.
    private var current: Int {
        var lo = 0, hi = lines.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    var body: some View {
        let i = current
        let visible = Array(max(0, i - 1)...min(lines.count - 1, max(0, i + 2)))
        VStack(spacing: fontSize * 0.08) {
            if i < 0 { countdown }
            ForEach(visible, id: \.self) { index in
                row(index, current: i)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)),
                                            removal: .opacity.combined(with: .move(edge: .top))))
            }
        }
        .animation(.easeOut(duration: 0.18), value: i)
    }

    /// Lead-in before the first line: three dots that count down.
    @ViewBuilder private var countdown: some View {
        let remaining = (lines.first?.time ?? 0) - position
        let dots = remaining < 3.2 ? max(1, Int(remaining.rounded(.up))) : 0
        Text(dots > 0 ? String(repeating: "● ", count: dots).trimmingCharacters(in: .whitespaces) : "♪")
            .font(.system(size: fontSize * 0.5, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.8))
            .shadow(color: .black.opacity(0.8), radius: 5, y: 1)
            .padding(.bottom, fontSize * 0.3)
    }

    private func row(_ index: Int, current: Int) -> some View {
        let line = lines[index]
        let isCurrent = index == current
        let started = position >= line.time
        // Two voices at once: an earlier line that is still being sung stays lit.
        let stillSung = started && !isCurrent && (line.end.map { position < $0 } ?? false)
        return Text(styled(line, active: isCurrent || stillSung, past: started && !isCurrent && !stillSung))
            .font(.system(size: fontSize, weight: .heavy, design: .rounded))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.55)
            .shadow(color: .black.opacity(0.85), radius: 5, y: 1)
            .shadow(color: .black.opacity(0.5), radius: 16)
            .scaleEffect(isCurrent ? 1 : 0.6)
            .frame(maxWidth: .infinity)
    }

    /// Colours a line. With per-word timing each word lights up as it is sung;
    /// with per-line timing the whole line lights up at once, because guessing
    /// the pace inside a line is what makes lyrics look out of time.
    private func styled(_ line: LyricLine, active: Bool, past: Bool) -> AttributedString {
        let unsung = 0.42, sung = 1.0
        if !active || line.words.isEmpty {
            var whole = AttributedString(line.text.isEmpty ? "♪" : line.text)
            whole.foregroundColor = Color.white.opacity(active ? sung : (past ? 0.26 : 0.55))
            return whole
        }
        var out = AttributedString()
        for (k, word) in line.words.enumerated() {
            let next = k + 1 < line.words.count ? line.words[k + 1].time : (line.end ?? word.time + 0.5)
            let level: Double
            if position >= next {
                level = sung
            } else if position >= word.time {
                // Light up quickly at the start of the word rather than snapping.
                let ramp = max(0.06, min(next - word.time, 0.18))
                level = unsung + (sung - unsung) * min(1, (position - word.time) / ramp)
            } else {
                level = unsung
            }
            var part = AttributedString(word.text)
            part.foregroundColor = Color.white.opacity(level)
            out.append(part)
        }
        return out
    }
}
