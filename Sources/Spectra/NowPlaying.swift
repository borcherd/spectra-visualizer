import AppKit

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    /// "Spotify" or "Music"
    var source: String
    var artworkURL: URL?

    func isSameSong(as other: Track) -> Bool {
        title == other.title && artist == other.artist && source == other.source
    }
}

/// Finds out what Spotify or Apple Music is playing, straight from the apps on
/// this Mac. No account, login or web API involved.
///
/// Two sources, used together:
/// - the broadcast each player sends when its playback changes (instant, no permission);
/// - a short AppleScript question to the player (needs the one-time "control
///   Spotify / Music" permission; also gives the state at launch and cover art).
final class NowPlaying: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
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

    private let work = DispatchQueue(label: "spectra.nowplaying", qos: .utility)
    private var started = false
    private var sawBroadcast = false
    private var queryRunning = false
    private var scriptFailures: [String: Int] = [:]
    private var pollTimer: Timer?
    private var artworkTask: URLSessionDataTask?

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
            self.set(nil, via: "quit")
        }

        refresh()
        // Safety net for players that never broadcast: ask every few seconds until one does.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            guard let self, !self.sawBroadcast else { return }
            self.refresh()
        }
    }

    // MARK: - Broadcasts

    private func handleBroadcast(_ note: Notification, from player: Player) {
        sawBroadcast = true
        let info = note.userInfo ?? [:]
        let state = (info["Player State"] as? String ?? "").lowercased()
        if state == "playing", let title = info["Name"] as? String, !title.isEmpty {
            let new = Track(title: title,
                            artist: info["Artist"] as? String ?? "",
                            album: info["Album"] as? String ?? "",
                            source: player.name,
                            artworkURL: nil)
            if track?.isSameSong(as: new) != true { set(new, via: "broadcast") }
            refresh() // picks up cover art when allowed
        } else if track?.source == player.name {
            set(nil, via: "broadcast")
        }
    }

    // MARK: - Asking the player directly

    private static func script(for player: Player) -> String {
        let art = player.name == "Spotify" ? "(artwork url of t)" : "\"\""
        return """
        tell application id "\(player.bundleID)"
            if player state is playing then
                set t to current track
                return (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & \(art)
            end if
        end tell
        return ""
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

    func refresh() {
        guard started, !queryRunning else { return }
        // Only talk to players that are already open; never launch one.
        let open = Self.players.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
                && scriptFailures[$0.bundleID, default: 0] < 2
        }
        guard !open.isEmpty else { return }
        queryRunning = true
        work.async { [weak self] in
            var found: Track?
            var answered: [String] = []
            var failed: [String] = []
            for player in open {
                let result = Self.run(Self.script(for: player))
                guard result.ok else { failed.append(player.bundleID); continue }
                answered.append(player.name)
                let parts = result.output.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
                if parts.count >= 2, !parts[0].isEmpty {
                    var url: URL?
                    if parts.count >= 4, let u = URL(string: parts[3]), u.scheme == "https" { url = u }
                    found = Track(title: parts[0], artist: parts[1], album: parts.count >= 3 ? parts[2] : "",
                                  source: player.name, artworkURL: url)
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.queryRunning = false
                for id in failed { self.scriptFailures[id, default: 0] += 1 }
                if let found {
                    self.set(found, via: "script")
                } else if let current = self.track, answered.contains(current.source) {
                    self.set(nil, via: "script")
                }
            }
        }
    }

    // MARK: - State

    private func set(_ new: Track?, via: String) {
        guard let new else {
            if track != nil {
                track = nil
                artwork = nil
                artworkTask?.cancel()
                Diagnostics.log("now playing: nothing (via \(via))")
            }
            return
        }
        let sameSong = track?.isSameSong(as: new) == true
        if sameSong, new.artworkURL == nil || new.artworkURL == track?.artworkURL { return }
        if !sameSong {
            artwork = nil
            changedAt = Date()
        }
        track = new
        Diagnostics.log("now playing: a song from \(new.source) (via \(via), cover art \(new.artworkURL == nil ? "no" : "yes"))")
        loadArtwork(new.artworkURL)
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
