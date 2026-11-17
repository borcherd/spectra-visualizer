import AppKit
import QuartzCore

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    /// "Spotify" or "Music"
    var source: String
    var artworkURL: URL?
    /// Seconds; 0 when unknown.
    var duration: Double = 0

    func isSameSong(as other: Track) -> Bool {
        title == other.title && artist == other.artist && source == other.source
    }
}

/// The link to Spotify / Apple Music on this Mac: what is playing, where in the
/// song it is, and the transport controls. No account, login or web API involved.
///
/// Two sources, used together:
/// - the broadcast each player sends when its playback changes (instant, no permission);
/// - short AppleScript questions and commands to the player (needs the one-time
///   "control Spotify / Music" permission).
final class NowPlaying: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPlaying = false
    /// Bumped whenever a different song starts.
    @Published private(set) var changedAt = Date.distantPast

    private struct Player {
        let bundleID: String
        let name: String
        let broadcast: String
    }

    private static let players = [
        Player(bundleID: "com.spotify.client", name: "Spotify", broadcast: "com.spotify.client.PlaybackStateChanged"),
        Player(bundleID: "com.apple.Music", name: "Music", broadcast: "com.apple.Music.playerInfo"),
    ]

    private let work = DispatchQueue(label: "spectra.nowplaying", qos: .userInitiated)
    private var started = false
    private var queryRunning = false
    private var queryAgain = false
    private var scriptFailures: [String: Int] = [:]
    private var pollTimer: Timer?
    private var pollTick = 0
    /// Set while lyrics are on screen: the position is then checked more often.
    var needsTightTiming = false
    private var artworkTask: URLSessionDataTask?

    // Playback position is measured now and then, and run forward by the clock in between.
    private var anchorPosition: Double = 0
    private var anchorTime: CFTimeInterval = CACurrentMediaTime()

    /// Seconds into the current song, right now.
    var position: Double {
        var p = anchorPosition
        if isPlaying { p += CACurrentMediaTime() - anchorTime }
        if let d = track?.duration, d > 0 { p = min(p, d) }
        return max(0, p)
    }

    /// A stand-in with a fixed song, for rendering the interface in tests.
    static func preview(_ track: Track, position: Double) -> NowPlaying {
        let player = NowPlaying()
        player.track = track
        player.anchorPosition = position
        return player
    }

    func start() {
        guard !started else { return }
        started = true

        let center = DistributedNotificationCenter.default()
        for player in Self.players {
            center.addObserver(forName: Notification.Name(player.broadcast), object: nil, queue: .main) { [weak self] note in
                self?.handleBroadcast(note, from: player)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let player = Self.players.first(where: { $0.bundleID == app.bundleIdentifier }),
                  self.track?.source == player.name else { return }
            self.clear(via: "quit")
        }

        refresh()
        // Regular check-in keeps the position honest and covers players that never broadcast.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollTick += 1
            let every = self.needsTightTiming && self.isPlaying ? 2 : 5
            if self.pollTick % every == 0 { self.refresh() }
        }
    }

    // MARK: - Controls

    func playPause() {
        guard let player = currentPlayer else { return }
        // Reflect it immediately; the follow-up refresh confirms.
        let p = position
        isPlaying.toggle()
        setAnchor(p)
        send("playpause", to: player)
    }

    func nextTrack() {
        guard let player = currentPlayer else { return }
        send("next track", to: player)
    }

    func previousTrack() {
        guard let player = currentPlayer else { return }
        send("previous track", to: player)
    }

    func seek(to seconds: Double) {
        guard let player = currentPlayer else { return }
        let target = max(0, seconds)
        setAnchor(target)
        objectWillChange.send()
        send("set player position to \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), target))", to: player)
    }

    private var currentPlayer: Player? {
        guard let source = track?.source else { return nil }
        return Self.players.first { $0.name == source }
    }

    private func send(_ command: String, to player: Player) {
        let source = "tell application id \"\(player.bundleID)\" to \(command)"
        work.async { [weak self] in
            _ = Self.run(source)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.refresh() }
        }
    }

    // MARK: - Broadcasts

    private func handleBroadcast(_ note: Notification, from player: Player) {
        let info = note.userInfo ?? [:]
        let state = (info["Player State"] as? String ?? "").lowercased()
        if state == "playing" || state == "paused", let title = info["Name"] as? String, !title.isEmpty {
            let new = Track(title: title,
                            artist: info["Artist"] as? String ?? "",
                            album: info["Album"] as? String ?? "",
                            source: player.name,
                            artworkURL: nil,
                            duration: 0)
            // A paused broadcast from another player must not steal the display.
            if state == "playing" || track == nil || track?.source == player.name {
                if track?.isSameSong(as: new) != true { apply(new, via: "broadcast") }
                let wasPlaying = isPlaying
                if wasPlaying != (state == "playing") {
                    let p = position
                    isPlaying = state == "playing"
                    setAnchor(p)
                }
                // Spotify includes where it is in the song: an instant, exact fix
                // on play, pause, seek and song change.
                if let p = info["Playback Position"] as? Double, p >= 0 {
                    setAnchor(p)
                    objectWillChange.send()
                }
            }
        } else if state == "stopped", track?.source == player.name {
            clear(via: "broadcast")
        }
        refresh() // exact position, duration and cover art
    }

    // MARK: - Asking the player directly

    private static func script(for player: Player) -> String {
        let spotify = player.name == "Spotify"
        let art = spotify ? "(artwork url of t)" : "\"\""
        let duration = spotify ? "((duration of t) / 1000)" : "(duration of t)"
        return """
        tell application id "\(player.bundleID)"
            if player state is playing then
                set s to "playing"
            else if player state is paused then
                set s to "paused"
            else
                return "stopped"
            end if
            set t to current track
            return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & \(art) & linefeed & \(duration) & linefeed & (player position)
        end tell
        """
    }

    private static func run(_ source: String) -> (output: String, ok: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return ("", false) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus == 0)
    }

    /// AppleScript prints numbers in the system's format, which may use a comma.
    private static func number(_ text: String) -> Double {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private struct Reading {
        var track: Track
        var playing: Bool
        var position: Double
        var takenAt: CFTimeInterval
    }

    func refresh() {
        guard started else { return }
        if queryRunning { queryAgain = true; return }
        // Only talk to players that are already open; never launch one.
        let open = Self.players.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
                && scriptFailures[$0.bundleID, default: 0] < 3
        }
        guard !open.isEmpty else { return }
        queryRunning = true
        work.async { [weak self] in
            var readings: [Reading] = []
            var answered: [String] = []
            var failed: [String] = []
            for player in open {
                let result = Self.run(Self.script(for: player))
                let after = CACurrentMediaTime()
                guard result.ok else { failed.append(player.bundleID); continue }
                answered.append(player.name)
                let parts = result.output.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
                guard parts.count >= 7, !parts[1].isEmpty else { continue }
                var url: URL?
                if let u = URL(string: parts[4]), u.scheme == "https" { url = u }
                let track = Track(title: parts[1], artist: parts[2], album: parts[3], source: player.name,
                                  artworkURL: url, duration: Self.number(parts[5]))
                // The position is the last thing the script asks for, so it was
                // read just before the call returned, not halfway through it.
                readings.append(Reading(track: track, playing: parts[0] == "playing",
                                        position: Self.number(parts[6]), takenAt: after - 0.015))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.queryRunning = false
                for id in failed { self.scriptFailures[id, default: 0] += 1 }
                // Prefer whichever player is actually playing, then the one already shown.
                let pick = readings.first { $0.playing }
                    ?? readings.first { $0.track.source == self.track?.source }
                    ?? readings.first
                if let pick {
                    self.apply(pick)
                } else if let current = self.track, answered.contains(current.source) {
                    self.clear(via: "script")
                }
                if self.queryAgain {
                    self.queryAgain = false
                    self.refresh()
                }
            }
        }
    }

    // MARK: - State

    private func setAnchor(_ position: Double, at time: CFTimeInterval = CACurrentMediaTime()) {
        anchorPosition = position
        anchorTime = time
    }

    private func apply(_ reading: Reading) {
        apply(reading.track, via: "script")
        let measured = reading.position + (reading.playing ? CACurrentMediaTime() - reading.takenAt : 0)
        let stateChanged = isPlaying != reading.playing
        if stateChanged { isPlaying = reading.playing }
        let error = measured - position
        if stateChanged || abs(error) > 0.75 {
            // A real jump (seek, new song, play / pause): take the reading as it is.
            setAnchor(measured)
            objectWillChange.send()
        } else {
            // Otherwise ease towards it. Each reading is a little noisy, so
            // averaging several lands closer than trusting any single one.
            setAnchor(position + error * 0.4)
        }
    }

    private func apply(_ new: Track, via: String) {
        var new = new
        let sameSong = track?.isSameSong(as: new) == true
        if sameSong, let old = track {
            // Keep details a broadcast does not carry.
            if new.artworkURL == nil { new.artworkURL = old.artworkURL }
            if new.duration <= 0 { new.duration = old.duration }
            if new == old { return }
        } else {
            artwork = nil
            changedAt = Date()
            setAnchor(0)
            Diagnostics.log("now playing: a song from \(new.source) (via \(via))")
        }
        let artChanged = new.artworkURL != track?.artworkURL
        track = new
        if artChanged { loadArtwork(new.artworkURL) }
    }

    private func clear(via: String) {
        guard track != nil else { return }
        track = nil
        artwork = nil
        isPlaying = false
        artworkTask?.cancel()
        Diagnostics.log("now playing: nothing (via \(via))")
    }

    private func loadArtwork(_ url: URL?) {
        artworkTask?.cancel()
        guard let url else { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.track?.artworkURL == url else { return }
                self.artwork = image
            }
        }
        artworkTask = task
        task.resume()
    }
}
