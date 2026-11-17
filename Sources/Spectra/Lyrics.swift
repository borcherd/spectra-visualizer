import Foundation

struct LyricWord: Equatable {
    let time: Double
    let text: String
}

struct LyricLine: Equatable {
    let time: Double
    let text: String
    /// When the line stops being sung, if the source says so.
    var end: Double?
    /// Per-word timing, when the source has it. Empty for line-timed lyrics.
    var words: [LyricWord] = []
}

/// Time-synced lyrics for karaoke mode, fetched from LRCLIB (lrclib.net), a free
/// public lyrics database. The only thing sent is the song's title, artist,
/// album and length.
///
/// LRCLIB has two kinds of timing. Every synced song has a start time per line;
/// many also have a start time per word. Word timing is what keeps fast or
/// overlapping vocals in step, so it is preferred whenever a version has it.
final class Lyrics: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case synced([LyricLine])
        case instrumental
        case unavailable
    }

    @Published private(set) var state: State = .idle

    private var loadedKey = ""
    private var cache: [String: State] = [:]
    private var task: Task<Void, Never>?

    func clear() {
        task?.cancel()
        loadedKey = ""
        state = .idle
    }

    func load(for track: Track) {
        let key = "\(track.artist)|\(track.title)|\(Int(track.duration.rounded()))"
        guard key != loadedKey else { return }
        loadedKey = key
        task?.cancel()
        if let cached = cache[key] {
            state = cached
            return
        }
        state = .loading
        task = Task { [weak self] in
            let result = await Self.fetch(track)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.loadedKey == key else { return }
                self.cache[key] = result
                self.state = result
                Diagnostics.log("lyrics: \(Self.describe(result))")
            }
        }
    }

    static func hasWordTiming(_ lines: [LyricLine]) -> Bool {
        let timed = lines.filter { !$0.words.isEmpty }.count
        return timed * 2 > lines.count
    }

    static func describe(_ state: State) -> String {
        switch state {
        case .synced(let lines):
            return "synced, \(lines.count) lines, \(hasWordTiming(lines) ? "timed per word" : "timed per line")"
        case .instrumental: return "instrumental"
        case .unavailable: return "none found"
        case .loading: return "loading"
        case .idle: return "idle"
        }
    }

    // MARK: - LRCLIB

    private struct Entry: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let syncedLyrics: String?
        let hasWordSync: Bool?
        let lyricsfile: String?
    }

    static func fetch(_ track: Track) async -> State {
        // 1. Exact match on title, artist, album and length.
        var exact: State?
        if track.duration > 0 {
            var query = [
                URLQueryItem(name: "track_name", value: track.title),
                URLQueryItem(name: "artist_name", value: track.artist),
                URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
            ]
            if !track.album.isEmpty { query.append(URLQueryItem(name: "album_name", value: track.album)) }
            if let entry: Entry = await get("get", query) { exact = usable(entry) }
        }
        if case .synced(let lines)? = exact, hasWordTiming(lines) { return exact! }

        // 2. Search for other versions of the same song: first with the title as
        //    given, then with extras like "- Remastered 2011" or "(feat. …)"
        //    removed. A word-timed version of the same length beats a line-timed one.
        var titles = [track.title]
        let simple = simplified(track.title)
        if simple != track.title, !simple.isEmpty { titles.append(simple) }
        var lineTimed: State?
        var sawInstrumental = false
        for title in titles {
            let query = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: track.artist),
            ]
            guard let entries: [Entry] = await get("search", query) else { continue }
            if entries.contains(where: { $0.instrumental == true }) { sawInstrumental = true }

            func distance(_ e: Entry) -> Double { abs((e.duration ?? 0) - track.duration) }
            let known = track.duration > 0
            let close = entries
                .filter { !known || distance($0) <= 4 }
                .sorted { known ? distance($0) < distance($1) : false }

            // Word timing only from a version whose length really matches.
            for entry in close where entry.hasWordSync == true && (!known || distance(entry) <= 2) {
                if case .synced(let lines)? = usable(entry), hasWordTiming(lines) { return .synced(lines) }
            }
            if lineTimed == nil {
                for entry in close {
                    if case .synced(let lines)? = usable(entry) { lineTimed = .synced(lines); break }
                }
            }
            if exact != nil || lineTimed != nil { break }
        }
        if let exact { return exact }
        if let lineTimed { return lineTimed }
        return sawInstrumental ? .instrumental : .unavailable
    }

    private static func usable(_ entry: Entry) -> State? {
        if entry.hasWordSync == true, let file = entry.lyricsfile {
            let lines = parseLyricsFile(file)
            if lines.count >= 2, hasWordTiming(lines) { return .synced(lines) }
        }
        if let synced = entry.syncedLyrics {
            let lines = parse(synced)
            if lines.count >= 2 { return .synced(lines) }
        }
        if entry.instrumental == true { return .instrumental }
        return nil
    }

    private static func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async -> T? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")
        components?.queryItems = query
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Spectra music visualiser", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// "Song - Remastered 2011" -> "Song"; "Song (feat. X)" -> "Song".
    static func simplified(_ title: String) -> String {
        var t = title
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Parsing

    /// Parses LRC text: `[mm:ss.xx] words`, possibly several timestamps per line.
    static func parse(_ lrc: String) -> [LyricLine] {
        guard let stamp = try? NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#) else { return [] }
        var lines: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                lines.append(LyricLine(time: minutes * 60 + seconds, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// Parses LRCLIB's word-timed "lyricsfile". It is YAML, but always in one
    /// fixed shape, so it is read line by line:
    ///
    ///     lines:
    ///     - text: Look, I was gonna go easy
    ///       start_ms: 1390
    ///       end_ms: 3859
    ///       words:
    ///       - text: 'Look, '
    ///         start_ms: 1390
    static func parseLyricsFile(_ yaml: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var inLines = false
        var text = ""
        var start: Double?
        var end: Double?
        var words: [LyricWord] = []
        var pendingWord: String?
        var open = false

        func flush() {
            defer { open = false; text = ""; start = nil; end = nil; words = []; pendingWord = nil }
            guard open, let start else { return }
            // Word texts carry their own spacing, so joining them rebuilds the line.
            let full = words.isEmpty ? text : words.map(\.text).joined()
            lines.append(LyricLine(time: start,
                                   text: full.trimmingCharacters(in: .whitespaces),
                                   end: end,
                                   words: words))
        }
        func milliseconds(_ line: String) -> Double? {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return Double(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)).map { $0 / 1000 }
        }

        for raw in yaml.components(separatedBy: "\n") {
            if !inLines {
                if raw.hasPrefix("lines:") { inLines = true }
                continue
            }
            if raw.hasPrefix("- text:") {
                flush()
                open = true
                text = scalar(String(raw.dropFirst("- text:".count)))
            } else if raw.hasPrefix("  - text:") {
                pendingWord = scalar(String(raw.dropFirst("  - text:".count)))
            } else if raw.hasPrefix("    start_ms:") {
                if let word = pendingWord, let t = milliseconds(raw) { words.append(LyricWord(time: t, text: word)) }
                pendingWord = nil
            } else if raw.hasPrefix("  start_ms:") {
                start = milliseconds(raw)
            } else if raw.hasPrefix("  end_ms:") {
                end = milliseconds(raw)
            } else if !raw.isEmpty, !raw.hasPrefix(" "), !raw.hasPrefix("-") {
                break // a new top-level section
            }
        }
        flush()
        return lines.sorted { $0.time < $1.time }
    }

    /// Reads one YAML value: plain, 'single quoted' or "double quoted".
    private static func scalar(_ raw: String) -> String {
        let body = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
        if body.count >= 2, body.hasPrefix("'"), body.hasSuffix("'") {
            return String(body.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if body.count >= 2, body.hasPrefix("\""), body.hasSuffix("\"") {
            // Close enough to a JSON string once \xNN escapes are rewritten.
            let json = body.replacingOccurrences(of: #"\\x([0-9A-Fa-f]{2})"#, with: "\\\\u00$1", options: .regularExpression)
            if let data = json.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
                return value
            }
            return String(body.dropFirst().dropLast())
        }
        return body
    }
}
