import SwiftUI
import MetalKit

/// Launch with `--status-file <path>` to have audio state changes appended to a file.
enum Diagnostics {
    private static let path: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--status-file"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()

    static func log(_ message: String) {
        NSLog("Spectra %@", message)
        guard let path, let data = (message + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

/// Shared app state: settings, favourites and the long-lived engine objects.
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.showSong { nowPlaying.start() }
        }
    }
    @Published var favourites: [Favourite] { didSet { Favourite.saveAll(favourites) } }
    @Published var showSettings: Bool { didSet { UserDefaults.standard.set(showSettings, forKey: "spectra.panelOpen") } }
    @Published var sceneName = ""
    @Published var audioStatus: AudioStatus = .starting
    @Published var fps: Double = 0

    let device: MTLDevice
    let analyzer = AudioAnalyzer()
    let director = SceneDirector()
    let tap = SystemAudioTap()
    let nowPlaying = NowPlaying()
    let renderer: Renderer

    private init() {
        settings = Settings.load()
        favourites = Favourite.loadAll()
        showSettings = UserDefaults.standard.object(forKey: "spectra.panelOpen") as? Bool ?? true
        guard let dev = MTLCreateSystemDefaultDevice() else { fatalError("Spectra needs a Metal-capable Mac.") }
        device = dev
        do {
            renderer = try Renderer(device: dev, analyzer: analyzer, director: director)
        } catch {
            fatalError("Could not start the renderer: \(error)")
        }

        renderer.settingsProvider = { [unowned self] in self.settings }
        renderer.tapErrorProvider = { [unowned self] in self.tap.lastError }
        renderer.onReport = { [unowned self] fps, status in
            if self.settings.showFPS, abs(self.fps - fps) > 0.5 { self.fps = fps }
            if self.audioStatus != status {
                self.audioStatus = status
                Diagnostics.log("audio status: \(status)")
            }
        }
        director.onSceneChange = { [unowned self] scene in
            if self.sceneName != scene.name { self.sceneName = scene.name }
        }
        tap.onSamples = { [analyzer] p, n in analyzer.pushFromTap(p, n) }
        director.next(settings: settings)
    }

    func startAudio() {
        tap.onStateChange = { [unowned self] in
            self.analyzer.sampleRate = self.tap.sampleRate
            Diagnostics.log("tap: running=\(self.tap.running) rate=\(Int(self.tap.sampleRate)) error=\(self.tap.lastError ?? "none")")
        }
        tap.start()
    }

    func nextScene() { director.next(settings: settings) }
    func previousScene() { director.back(settings: settings) }
    func toggleLock() { settings.locked.toggle() }

    func saveFavourite() {
        let scene = director.current
        guard !favourites.contains(where: { $0.seed == scene.seed }) else { return }
        favourites.append(Favourite(seed: scene.seed, name: scene.name))
    }

    func load(_ fav: Favourite) {
        director.go(to: fav.seed, settings: settings)
    }

    func remove(_ fav: Favourite) {
        favourites.removeAll { $0.id == fav.id }
    }

    func resetSettings() {
        var fresh = Settings()
        fresh.advancedMode = settings.advancedMode
        settings = fresh
    }

    func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.startAudio()
        if AppState.shared.settings.showSong { AppState.shared.nowPlaying.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.tap.stop()
    }
}

struct SpectraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Spectra", id: "main") {
            ContentView(state: state, nowPlaying: state.nowPlaying)
                .frame(minWidth: 640, minHeight: 400)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(state.showSettings ? "Hide Settings" : "Show Settings") {
                    withAnimation(.easeOut(duration: 0.2)) { state.showSettings.toggle() }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scene") {
                Button("Next Scene") { state.nextScene() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous Scene") { state.previousScene() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button(state.settings.locked ? "Unlock Scene" : "Lock Scene") { state.toggleLock() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Save as Favourite") { state.saveFavourite() }
                    .keyboardShortcut("d", modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var nowPlaying: NowPlaying
    @State private var hovering = false
    @State private var songIsNew = false

    var body: some View {
        ZStack {
            MetalView(state: state)
                .ignoresSafeArea()

            // Top-right: gear to bring the panel back.
            if !state.showSettings {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { state.showSettings = true }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 14, weight: .medium))
                                .padding(8)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.85))
                        .opacity(hovering ? 1 : 0)
                        .help("Show settings (S)")
                    }
                    Spacer()
                }
                .padding(12)
            }

            // Bottom-left: status.
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        statusBanner
                        if state.settings.showSong, let track = nowPlaying.track,
                           state.settings.keepSong || songIsNew || hovering {
                            SongLabel(track: track, artwork: nowPlaying.artwork)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        if state.showSettings || hovering {
                            HStack(spacing: 6) {
                                if state.settings.locked { Image(systemName: "lock.fill") }
                                Text(state.sceneName)
                                if state.settings.showFPS { Text("· \(Int(state.fps.rounded())) fps") }
                            }
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    Spacer()
                }
            }
            .padding(14)
            .allowsHitTesting(statusNeedsAction)

            if state.showSettings {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    SettingsPanel(state: state)
                }
                .transition(.move(edge: .trailing))
            }
        }
        .background(Color.black)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.5), value: songIsNew)
        .animation(.easeInOut(duration: 0.5), value: nowPlaying.track)
        .task(id: nowPlaying.changedAt) {
            // Show the title for a while each time a new song starts.
            guard nowPlaying.track != nil else { return }
            songIsNew = true
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled { songIsNew = false }
        }
    }

    private var statusNeedsAction: Bool {
        switch state.audioStatus {
        case .silent, .error: return true
        default: return false
        }
    }

    @ViewBuilder private var statusBanner: some View {
        switch state.audioStatus {
        case .silent:
            banner(icon: "speaker.slash",
                   text: "No audio detected. Play something — or, if music is already playing, allow Spectra under Privacy & Security › Screen & System Audio Recording.")
        case .error(let message):
            banner(icon: "exclamationmark.triangle", text: message)
        default:
            EmptyView()
        }
    }

    private func banner(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Retry") { state.startAudio() }
                    Button("Use demo signal") { state.settings.demoMode = true }
                }
                .controlSize(.small)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.9))
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Cover art, title and artist of the song that is playing.
struct SongLabel: View {
    let track: Track
    let artwork: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(0.1))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(maxWidth: 360, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The MTKView, plus bare-key shortcuts and double-click for full screen.
final class VizView: MTKView {
    var onKey: ((NSEvent) -> Bool)?
    /// Asked once a second; when true and the mouse has been still, the cursor is hidden.
    var canHideCursor: (() -> Bool)?
    private var lastMouseMove = Date()
    private var cursorTimer: Timer?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        lastMouseMove = Date()
        super.mouseMoved(with: event)
    }

    private func startCursorTimer() {
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let window = self.window, window.isKeyWindow,
                  self.canHideCursor?() == true,
                  Date().timeIntervalSince(self.lastMouseMove) > 2.5 else { return }
            let mouse = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if self.bounds.contains(mouse) { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.backgroundColor = .black
        if window != nil { startCursorTimer() } else { cursorTimer?.invalidate() }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { window?.toggleFullScreen(nil) } else { super.mouseDown(with: event) }
    }
}

struct MetalView: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> VizView {
        let view = VizView(frame: .zero, device: state.device)
        view.colorPixelFormat = Renderer.outputFormat
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.delegate = state.renderer
        view.canHideCursor = { [state] in !state.showSettings }
        view.onKey = { [state] event in
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            switch event.keyCode {
            case 49, 124: state.nextScene(); return true          // space, right arrow
            case 123: state.previousScene(); return true          // left arrow
            default: break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s": withAnimation(.easeOut(duration: 0.2)) { state.showSettings.toggle() }; return true
            case "l": state.toggleLock(); return true
            case "f": state.toggleFullScreen(); return true
            case "d": state.saveFavourite(); return true
            default: return false
            }
        }
        return view
    }

    func updateNSView(_ nsView: VizView, context: Context) {}
}
