import SwiftUI

struct SettingsPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                sceneSection
                lookSection
                layersSection
                audioSection
                finishSection
                performanceSection
                Text("Space next · ← back · L lock · D favourite · F full screen · S hide panel")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 292)
        .background(Color.black.opacity(0.78))
        .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1) }
        .controlSize(.small)
        .font(.system(size: 12))
    }

    // MARK: Sections

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
                .help("Hide settings (S)")
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

    private var sceneSection: some View {
        Section("Scene") {
            HStack {
                Text(state.sceneName).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                Spacer()
            }
            HStack {
                Button { state.previousScene() } label: { Image(systemName: "backward.fill") }
                Button { state.nextScene() } label: { Label("New scene", systemImage: "dice") }
                Button { state.toggleLock() } label: {
                    Image(systemName: state.settings.locked ? "lock.fill" : "lock.open")
                }
                .help("Lock this scene")
                Button { state.saveFavourite() } label: { Image(systemName: "star") }
                    .help("Save as favourite")
            }
            Toggle("Change scenes automatically", isOn: $state.settings.autoChange)
            if state.settings.autoChange {
                SliderRow(title: "Every", value: $state.settings.interval, range: 5...120, format: "%.0f s")
            }
            SliderRow(title: "Morph time", value: $state.settings.morphSeconds, range: 0.2...10, format: "%.1f s")

            if !state.favourites.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Favourites").foregroundStyle(.white.opacity(0.5)).font(.system(size: 11))
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
                        }
                    }
                }
            }
        }
    }

    private var lookSection: some View {
        Section("Look") {
            LabeledRow("Palette") {
                Picker("", selection: $state.settings.palette) {
                    Text("Random per scene").tag("auto")
                    Divider()
                    ForEach(Palette.presets, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
            }
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
            SliderRow(title: "Intensity", value: $state.settings.intensity, range: 0.2...2.5)
            SliderRow(title: "Glow", value: $state.settings.glow, range: 0...2.5)
            SliderRow(title: "Trails", value: $state.settings.trails, range: 0...1)
            SliderRow(title: "Motion", value: $state.settings.motion, range: 0...2.5)
            SliderRow(title: "Colour cycling", value: $state.settings.colorSpeed, range: 0...4)
        }
    }

    private var layersSection: some View {
        Section("Layers") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                Toggle("Waveform", isOn: $state.settings.layerWave)
                Toggle("EQ bars", isOn: $state.settings.layerBars)
                Toggle("Orbs", isOn: $state.settings.layerOrbs)
                Toggle("Plasma lines", isOn: $state.settings.layerPlasma)
                Toggle("Shapes", isOn: $state.settings.layerShapes)
                Toggle("Beat bursts", isOn: $state.settings.layerBurst)
                Toggle("Sparks", isOn: $state.settings.layerSparks)
            }
            Toggle("Always show the equaliser", isOn: $state.settings.alwaysBars)
                .disabled(!state.settings.layerBars)
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            SliderRow(title: "Sensitivity", value: $state.settings.sensitivity, range: 0.3...3)
            SliderRow(title: "Smoothing", value: $state.settings.smoothing, range: 0...1)
            Toggle("Use built-in demo signal", isOn: $state.settings.demoMode)
        }
    }

    private var finishSection: some View {
        Section("Finish") {
            SliderRow(title: "Film grain", value: $state.settings.grain, range: 0...1)
            SliderRow(title: "Vignette", value: $state.settings.vignette, range: 0...1)
            SliderRow(title: "Colour fringing", value: $state.settings.chroma, range: 0...1.5)
            SliderRow(title: "Scanlines", value: $state.settings.scanlines, range: 0...1)
        }
    }

    private var performanceSection: some View {
        Section("Performance") {
            LabeledRow("Frame rate") {
                Picker("", selection: $state.settings.fpsCap) {
                    Text("Display max").tag(0)
                    Text("120 fps").tag(120)
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                }
                .labelsHidden()
            }
            LabeledRow("Resolution") {
                Picker("", selection: $state.settings.renderScale) {
                    Text("50%").tag(0.5)
                    Text("75%").tag(0.75)
                    Text("100%").tag(1.0)
                }
                .labelsHidden()
            }
            Toggle("Show frame rate", isOn: $state.settings.showFPS)
        }
    }
}

// MARK: - Small building blocks

private struct Section<Content: View>: View {
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
