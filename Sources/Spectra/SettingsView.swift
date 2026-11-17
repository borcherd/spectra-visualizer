import SwiftUI

/// The side panel. Simple mode shows a handful of everyday controls; Advanced
/// mode adds every fine-tuning control below them.
struct SettingsPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("", selection: $state.settings.advancedMode) {
                    Text("Simple").tag(false)
                    Text("Advanced").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                sceneControls
                simpleControls
                favourites
                if state.settings.advancedMode { advancedControls }
                Text("Space play/pause · N new scene · K karaoke · ↑ ↓ lyrics earlier / later · L lock · F full screen · S hide this panel")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 280)
        .background(Color.black.opacity(0.78))
        .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1) }
        .controlSize(.small)
        .font(.system(size: 12))
    }

    // MARK: Everyday controls

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Spectra").font(.system(size: 17, weight: .semibold))
            Spacer()
            statusDot
            Button {
                withAnimation(.easeOut(duration: 0.2)) { state.showSettings = false }
            } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
                .help("Hide this panel (S)")
        }
    }

    private var statusDot: some View {
        let (color, label): (Color, String) = {
            switch state.audioStatus {
            case .listening: return (.green, "Listening")
            case .demo: return (.blue, "Demo signal")
            case .silent: return (.orange, "Silent")
            case .starting: return (.gray, "Starting")
            case .error: return (.red, "Audio error")
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.trailing, 6)
    }

    private var sceneControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { state.nextScene() } label: {
                    Label("New scene", systemImage: "dice")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.18))

                Button { state.toggleLock() } label: {
                    Image(systemName: state.settings.locked ? "lock.fill" : "lock.open")
                        .frame(width: 18)
                }
                .controlSize(.large)
                .help(state.settings.locked ? "Unlock: let scenes change again" : "Lock: stay on this scene")

                Button { state.saveFavourite() } label: {
                    Image(systemName: isFavourite ? "star.fill" : "star").frame(width: 18)
                }
                .controlSize(.large)
                .help("Save this scene as a favourite")
            }
            Text(state.sceneName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var isFavourite: Bool {
        state.favourites.contains { $0.seed == state.director.current.seed }
    }

    private var simpleControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Style")
                Picker("", selection: $state.settings.mood) {
                    Text("Mix").tag("mix")
                    Text("Classic").tag("classic")
                    Text("Trippy").tag("trippy")
                    Text("Chill").tag("chill")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            LabeledRow("Colours") {
                Picker("", selection: $state.settings.palette) {
                    Text("Surprise me").tag("auto")
                    Divider()
                    ForEach(Palette.presets, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Energy")
                HStack(spacing: 6) {
                    Image(systemName: "tortoise").foregroundStyle(.white.opacity(0.4))
                    Slider(value: $state.settings.energy, in: 0...1)
                    Image(systemName: "hare").foregroundStyle(.white.opacity(0.4))
                }
            }
            if state.settings.advancedMode {
                Toggle("Change scenes automatically", isOn: $state.settings.autoChange)
                if state.settings.autoChange {
                    SliderRow(title: "Every", value: $state.settings.interval, range: 5...180, format: "%.0f s")
                }
            } else {
                LabeledRow("Change scene") {
                    Picker("", selection: changeEvery) {
                        Text("Never").tag(0)
                        Divider()
                        Text("Every 10 s").tag(10)
                        Text("Every 30 s").tag(30)
                        Text("Every minute").tag(60)
                        Text("Every 2 minutes").tag(120)
                    }
                    .labelsHidden()
                }
            }
            Toggle("Equaliser bars", isOn: equaliser)
            Toggle("Song title", isOn: $state.settings.showSong)
            Toggle("Karaoke lyrics", isOn: $state.settings.karaoke)
            if state.settings.karaoke {
                HStack(spacing: 6) {
                    Text("Lyrics")
                    Spacer()
                    Button { state.nudgeLyrics(-0.1) } label: { Image(systemName: "minus") }
                        .help("Show lyrics later (↓)")
                    Text(AppState.describeOffset(state.settings.lyricsOffset))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(minWidth: 86)
                    Button { state.nudgeLyrics(0.1) } label: { Image(systemName: "plus") }
                        .help("Show lyrics earlier (↑)")
                }
            }
            if state.settings.advancedMode, state.settings.showSong {
                Toggle("Keep the song title on screen", isOn: $state.settings.keepSong)
            }
        }
    }

    /// 0 = never; otherwise seconds, snapped to the options on offer.
    private var changeEvery: Binding<Int> {
        Binding(
            get: {
                guard state.settings.autoChange else { return 0 }
                let options = [10, 30, 60, 120]
                return options.min { abs(Double($0) - state.settings.interval) < abs(Double($1) - state.settings.interval) } ?? 30
            },
            set: { value in
                if value == 0 {
                    state.settings.autoChange = false
                } else {
                    state.settings.autoChange = true
                    state.settings.interval = Double(value)
                }
            })
    }

    private var equaliser: Binding<Bool> {
        Binding(
            get: { state.settings.alwaysBars && state.settings.layerBars },
            set: { on in
                state.settings.alwaysBars = on
                if on { state.settings.layerBars = true }
            })
    }

    @ViewBuilder private var favourites: some View {
        if !state.favourites.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("FAVOURITES")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                ForEach(state.favourites) { fav in
                    HStack {
                        Button { state.load(fav) } label: {
                            HStack {
                                Image(systemName: "star.fill").foregroundStyle(.yellow.opacity(0.8))
                                Text(fav.name).font(.system(size: 11, design: .monospaced))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { state.remove(fav) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.4))
                            .help("Remove")
                    }
                }
            }
        }
    }

    // MARK: Everything else

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 14) {
                Group_("Look") {
                    LabeledRow("Kaleidoscope") {
                        Picker("", selection: $state.settings.kaleido) {
                            Text("Scene decides").tag(-1)
                            Text("Off").tag(0)
                            Divider()
                            ForEach([3, 4, 5, 6, 8, 12], id: \.self) { Text("\($0) segments").tag($0) }
                        }
                        .labelsHidden()
                    }
                    Toggle("Mirror left / right", isOn: $state.settings.mirror)
                    SliderRow(title: "Brightness", value: $state.settings.intensity, range: 0.2...2.5)
                    SliderRow(title: "Glow", value: $state.settings.glow, range: 0...2.5)
                    SliderRow(title: "Trails", value: $state.settings.trails, range: 0...1)
                    SliderRow(title: "Motion", value: $state.settings.motion, range: 0...2.5)
                    SliderRow(title: "Colour cycling", value: $state.settings.colorSpeed, range: 0...4)
                    SliderRow(title: "Scene blend time", value: $state.settings.morphSeconds, range: 0.2...10, format: "%.1f s")
                }
                Group_("Elements") {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                        Toggle("Waveform", isOn: $state.settings.layerWave)
                        Toggle("EQ bars", isOn: $state.settings.layerBars)
                        Toggle("Orbs", isOn: $state.settings.layerOrbs)
                        Toggle("Plasma lines", isOn: $state.settings.layerPlasma)
                        Toggle("Shapes", isOn: $state.settings.layerShapes)
                        Toggle("Beat bursts", isOn: $state.settings.layerBurst)
                        Toggle("Sparks", isOn: $state.settings.layerSparks)
                    }
                }
                Group_("Audio") {
                    SliderRow(title: "Sensitivity", value: $state.settings.sensitivity, range: 0.3...3)
                    SliderRow(title: "Smoothing", value: $state.settings.smoothing, range: 0...1)
                    Toggle("Use built-in demo signal", isOn: $state.settings.demoMode)
                }
                Group_("Finish") {
                    SliderRow(title: "Film grain", value: $state.settings.grain, range: 0...1)
                    SliderRow(title: "Vignette", value: $state.settings.vignette, range: 0...1)
                    SliderRow(title: "Colour fringing", value: $state.settings.chroma, range: 0...1.5)
                    SliderRow(title: "Scanlines", value: $state.settings.scanlines, range: 0...1)
                }
                Group_("Performance") {
                    LabeledRow("Frame rate") {
                        Picker("", selection: $state.settings.fpsCap) {
                            Text("Automatic").tag(0)
                            Divider()
                            Text("120 fps").tag(120)
                            Text("60 fps").tag(60)
                            Text("30 fps").tag(30)
                        }
                        .labelsHidden()
                    }
                    LabeledRow("Detail") {
                        Picker("", selection: $state.settings.resolution) {
                            Text("Automatic").tag(0.0)
                            Divider()
                            Text("Low").tag(0.5)
                            Text("Medium").tag(0.75)
                            Text("Full").tag(1.0)
                        }
                        .labelsHidden()
                    }
                    Toggle("Show frame rate", isOn: $state.settings.showFPS)
                }
                Button("Reset everything to defaults") { state.resetSettings() }
        }
    }
}

// MARK: - Small building blocks

private struct Group_<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.white.opacity(0.45))
            content
        }
    }
}

private struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            content.frame(maxWidth: 150)
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format = "%.2f"

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: $value, in: range)
        }
    }
}
