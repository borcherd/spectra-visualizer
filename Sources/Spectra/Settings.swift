import Foundation

/// Everything the user can tweak. Persisted as JSON in UserDefaults.
struct Settings: Codable, Equatable {
    // Audio
    var sensitivity: Double = 1.0
    var smoothing: Double = 0.5
    var demoMode = false

    // Scenes
    var autoChange = true
    var interval: Double = 25
    var morphSeconds: Double = 3
    var locked = false

    // Look
    var palette = "auto"
    var colorSpeed: Double = 1
    var intensity: Double = 1
    var glow: Double = 1
    var trails: Double = 0.5
    var motion: Double = 1
    /// -1 = let the scene decide, 0 = off, n = force n segments
    var kaleido = -1
    var mirror = false

    // Layers
    var layerWave = true
    var layerBars = true
    var layerOrbs = true
    var layerPlasma = true
    var layerShapes = true
    var layerBurst = true
    var layerSparks = true
    var alwaysBars = false

    // Finish
    var grain: Double = 0.3
    var vignette: Double = 0.5
    var chroma: Double = 0.4
    var scanlines: Double = 0

    // Performance
    /// 0 = display maximum
    var fpsCap = 0
    var renderScale: Double = 0.75
    var showFPS = false

    var layerSignature: String {
        [layerWave, layerBars, layerOrbs, layerPlasma, layerShapes, layerBurst, layerSparks]
            .map { $0 ? "1" : "0" }.joined()
    }

    private static let key = "spectra.settings.v1"

    /// Loads saved settings, keeping defaults for any field added since they were saved.
    static func load() -> Settings {
        let def = Settings()
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(def),
              var merged = try? JSONSerialization.jsonObject(with: defData) as? [String: Any]
        else { return def }
        for (k, v) in saved where merged[k] != nil { merged[k] = v }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let out = try? JSONDecoder().decode(Settings.self, from: mergedData)
        else { return def }
        return out
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

struct Favourite: Codable, Identifiable, Equatable {
    var id = UUID()
    var seed: UInt64
    var name: String

    private static let key = "spectra.favourites.v1"

    static func loadAll() -> [Favourite] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Favourite].self, from: data) else { return [] }
        return list
    }

    static func saveAll(_ list: [Favourite]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
