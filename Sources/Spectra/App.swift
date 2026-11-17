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

    @Published var settings: Settings { didSet { if settings != oldValue { settings.save() } } }
    @Published var favourites: [Favourite] { didSet { Favourite.saveAll(favourites) } }
    @Published var showSettings = true
    @Published var sceneName = ""
    @Published var audioStatus: AudioStatus = .starting
    @Published var fps: Double = 0

    let device: MTLDevice
    let analyzer = AudioAnalyzer()
    let director = SceneDirector()
    let tap = SystemAudioTap()
    let renderer: Renderer

    private init() {
        settings = Settings.load()
        favourites = Favourite.loadAll()
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

    func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.startAudio()
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
            ContentView(state: state)
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
    @State private var hovering = false

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

/// The MTKView, plus bare-key shortcuts and double-click for full screen.
final class VizView: MTKView {
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.backgroundColor = .black
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
