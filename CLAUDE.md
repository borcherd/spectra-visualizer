# Spectra

Native macOS music visualiser: Swift, SwiftUI shell, Metal rendering, Core Audio process tap for system audio. SwiftPM executable packaged into an `.app` by `build.sh`.

## Commands

- `./build.sh` builds and signs `build/Spectra.app`; `./build.sh run` also launches it.
- `swift build -c release` for a quick compile check.
- Visual check without the UI: `.build/release/Spectra --snapshot build/snapshots/sheet.png --scenes 12 --cols 4 --size 480x270 --seed 1` renders random scenes against the demo synth into one PNG. Extra flags: `--frames`, `--kaleido N`, `--palette <id>`, `--mood <mix|classic|trippy|chill>`, `--bars`, `--auto-res`, `--resize-to WxH` (simulates moving to another screen), `--icon`. Always look at a contact sheet after changing shaders or scene generation, and include a wide (`860x360`) and a portrait (`360x640`) run when touching layout maths.
- Lyrics lookup check: `.build/release/Spectra --lyrics-test "<artist>" "<title>" [seconds]`.
- Interface check: `.build/release/Spectra --ui-test build/snapshots/ui.png` draws the karaoke text and player bar off screen (sliders show as yellow placeholders there).
- Chain test runs after the build with `&&`. Running `.build/release/Spectra` with a flag it does not know (for example a stale binary after a failed build) launches the full app unpackaged, which cannot capture audio and confuses the owner.
- Audio diagnostics: `open build/Spectra.app --args --status-file "$PWD/build/status.log"` appends tap and audio-status changes to that file.

## Layout (`Sources/Spectra`)

- `AudioTap.swift`: system audio capture (process tap + private aggregate device). Starts off the main thread because the permission prompt can block.
- `AudioAnalyzer.swift`: FFT, log spectrum, peaks, waveform, band levels, beat detection, plus `DemoSynth`.
- `Scene.swift`: `Slot` (the uniform layout), seeded `SceneGenerator` archetypes, `SceneDirector` (morphing, auto-change).
- `Shaders.swift`: all Metal shader source, compiled at launch. `#define u_<slot>` lines are generated from `Slot`, so adding a uniform means adding a `Slot` case only.
- `Renderer.swift`: passes are feedback -> bright -> blur x2 -> composite.
- `Settings.swift`, `SettingsView.swift`, `App.swift`: persisted settings, the panel, window and shortcuts.
- `NowPlaying.swift`: current song, playback position (anchored by Spotify's broadcast position, then eased towards `osascript` readings every 2 s while lyrics show) and transport commands for Spotify / Music via their playback broadcasts plus an `osascript` query (run as a subprocess so the Automation permission prompt cannot block the UI). Only queries players that are already running. The system-wide now-playing API is private and locked down, so other sources (browsers etc.) are not covered.
- `Lyrics.swift`: time-synced lyrics from LRCLIB. Prefers a version with per-word timing (the YAML `lyricsfile` field, parsed line by line) over per-line LRC. Never estimate pace inside a line-timed line: the guess is what looked out of time.
- `PlayerViews.swift`: the hover player bar and the karaoke lyric display.
- `Snapshot.swift`, `UITest.swift`: the headless contact-sheet and interface-render modes.

## Notes

- Keep the panel simple: the owner wants few controls. The panel has a Simple / Advanced switch. Simple shows only the everyday controls (new scene, lock, favourite, Style, Colours, Energy, Change scene, Equaliser bars, Song title); anything new goes in Advanced unless asked otherwise.
- Scene coordinates are normalised so the shorter screen side is 1 (`ext` in the shaders). Never use raw aspect for layout.

- Shaders are compiled from a Swift string at runtime; a shader error only shows up when the app or snapshot mode runs, not at `swift build`.
- The app must run from the signed bundle for the audio permission prompt to work (`NSAudioCaptureUsageDescription` lives in `Support/Info.plist`).
- v2 is in progress on branch `v2-player-karaoke`; see the roadmap in `README.md` for what is done and what is next.
- Do not pause, skip or seek the owner's music to test the player controls; ask them to try those.
