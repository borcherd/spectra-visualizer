import Foundation

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--lyrics-test"), i + 2 < arguments.count {
    // `Spectra --lyrics-test "<artist>" "<title>" [seconds]`: checks the lyrics lookup from the terminal.
    let length = arguments.count > i + 3 ? Double(arguments[i + 3]) ?? 0 : 0
    let track = Track(title: arguments[i + 2], artist: arguments[i + 1], album: "", source: "test",
                      artworkURL: nil, duration: length)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let result = await Lyrics.fetch(track)
        print(Lyrics.describe(result))
        if case .synced(let lines) = result {
            for line in lines.prefix(4) { print(String(format: "%7.2f  %@", line.time, line.text)) }
        }
        done.signal()
    }
    done.wait()
    exit(0)
} else if let i = arguments.firstIndex(of: "--ui-test"), i + 1 < arguments.count {
    let path = arguments[i + 1]
    exit(MainActor.assumeIsolated { UITest.run(path) })
} else if arguments.contains("--snapshot") {
    exit(Snapshot.run(arguments))
} else {
    SpectraApp.main()
}
