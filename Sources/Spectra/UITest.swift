import SwiftUI
import ImageIO

/// `Spectra --ui-test out.png`: draws the karaoke lyrics and the player bar off
/// screen with a made-up song, so their layout can be checked without the app.
/// (Sliders are AppKit controls and show as placeholders in this kind of render.)
enum UITest {
    @MainActor static func run(_ path: String) -> Int32 {
        func timed(_ start: Double, _ end: Double, _ text: String) -> LyricLine {
            let parts = text.split(separator: " ").map { String($0) + " " }
            let step = (end - start) / Double(max(1, parts.count))
            let words = parts.enumerated().map { LyricWord(time: start + Double($0.offset) * step, text: $0.element) }
            return LyricLine(time: start, text: text, end: end, words: words)
        }
        let lines = [
            timed(0, 9.5, "An earlier line that another voice is still singing"),
            timed(6, 11, "This is the line being sung word by word right now"),
            timed(12, 16, "And here is the one that comes next"),
            LyricLine(time: 18, text: "Followed by a much longer line with no word timing that should shrink or wrap instead of running off the screen"),
        ]
        let track = Track(title: "A Song With A Fairly Long Title", artist: "Some Artist", album: "Album",
                          source: "Spotify", artworkURL: nil, duration: 215)
        let player = NowPlaying.preview(track, position: 8.2)

        func screen(width: CGFloat, height: CGFloat) -> some View {
            ZStack {
                LinearGradient(colors: [.purple, .blue, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                Color.black.opacity(0.22)
                SyncedLyrics(lines: lines, position: 8.2, fontSize: min(64, max(20, width * 0.042)))
                    .padding(.horizontal, width * 0.07)
                VStack {
                    Spacer()
                    HStack {
                        PlayerBar(player: player, state: AppState.shared, track: track)
                        Spacer(minLength: 0)
                    }
                }
                .padding(14)
            }
            .frame(width: width, height: height)
        }

        let content = VStack(spacing: 8) {
            screen(width: 1180, height: 620)
            screen(width: 640, height: 400)
        }
        .padding(8)
        .background(Color.gray)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return 1 }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? 0 : 1
    }
}
