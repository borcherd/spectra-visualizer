import Foundation

/// One float per slot, shared verbatim with the shaders (see Shaders.swift,
/// which generates a `#define u_<name>` for every case).
enum Slot: Int, CaseIterable {
    // Frame globals
    case time, dt60, aspect, resX, resY, bass, mid, treble, level, beat, bassAccum, seed, flash
    // User settings
    case intensity, glow, grain, vignette, chroma, scan, mirror, warpGlobal
    // Scene: motion of the feedback buffer
    case zoom, zoomBass, zoomCurve, rot, rotBass, swirl, swirlFreq, warpAmp, warpFreq, warpSpeed
    case ripple, rippleFreq, driftX, driftY, decay, blur, hueShift, kaleidoN, kaleidoRot
    // Scene: layers
    case waveAmt, waveMode, waveAmp, waveRadius, waveThick, waveY
    case barsAmt, barsInk, barsMode, barsCount, barsSeg
    case orbAmt, orbCount, orbSpeed, orbSpread, orbSize
    case plasmaAmt, plasmaScale, plasmaSpeed, plasmaLines
    case shapeAmt, shapeSides, shapeCount, shapeSpin, shapeSize
    case burstAmt, burstRays, sparkAmt
    // Scene: palette
    case palA0, palA1, palA2, palB0, palB1, palB2, palC0, palC1, palC2, palD0, palD1, palD2, palPhase, palSpread
}

let slotCount = 128

struct RNG {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * unit() }
    mutating func chance(_ p: Float) -> Bool { unit() < p }
    mutating func sign() -> Float { chance(0.5) ? 1 : -1 }
    mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
}

/// Cosine palette: colour(t) = a + b * cos(2π (c t + d)).
struct Palette {
    var a, b, c, d: SIMD3<Float>

    static let presets: [(id: String, name: String, p: Palette)] = [
        ("neon", "Neon", Palette(a: .init(0.5, 0.5, 0.5), b: .init(0.5, 0.5, 0.5), c: .init(1, 1, 1), d: .init(0.0, 0.33, 0.67))),
        ("fire", "Fire", Palette(a: .init(0.55, 0.28, 0.08), b: .init(0.45, 0.28, 0.08), c: .init(1, 1, 1), d: .init(0.0, 0.08, 0.2))),
        ("ice", "Ice", Palette(a: .init(0.25, 0.5, 0.65), b: .init(0.25, 0.4, 0.35), c: .init(1, 1, 1), d: .init(0.55, 0.2, 0.0))),
        ("vapor", "Vaporwave", Palette(a: .init(0.6, 0.35, 0.65), b: .init(0.4, 0.35, 0.35), c: .init(1, 1, 1), d: .init(0.0, 0.5, 0.25))),
        ("acid", "Acid", Palette(a: .init(0.45, 0.55, 0.2), b: .init(0.45, 0.45, 0.2), c: .init(1, 1, 2), d: .init(0.3, 0.0, 0.6))),
        ("sunset", "Sunset", Palette(a: .init(0.6, 0.35, 0.35), b: .init(0.4, 0.3, 0.3), c: .init(1, 1, 1), d: .init(0.0, 0.15, 0.45))),
        ("aurora", "Aurora", Palette(a: .init(0.25, 0.55, 0.5), b: .init(0.25, 0.45, 0.45), c: .init(1, 1, 1), d: .init(0.7, 0.0, 0.3))),
        ("mono", "Mono", Palette(a: .init(0.55, 0.55, 0.55), b: .init(0.45, 0.45, 0.45), c: .init(1, 1, 1), d: .init(0.0, 0.02, 0.05))),
    ]

    static func preset(_ id: String) -> Palette? { presets.first { $0.id == id }?.p }

    /// Random but always colourful: the three channels are kept well out of
    /// phase with each other so the palette never collapses to grey or white.
    static func random(_ r: inout RNG) -> Palette {
        let a = SIMD3<Float>(r.range(0.42, 0.58), r.range(0.42, 0.58), r.range(0.42, 0.58))
        let b = SIMD3<Float>(min(a.x, r.range(0.38, 0.55)), min(a.y, r.range(0.38, 0.55)), min(a.z, r.range(0.38, 0.55)))
        let c: SIMD3<Float> = r.chance(0.75) ? .init(1, 1, 1) : .init(r.pick([1, 1, 2]), r.pick([1, 1, 2]), r.pick([1, 2, 1]))
        let base = r.unit()
        let gap = r.range(0.18, 0.4) * r.sign()
        var phases: [Float] = [base, base + gap, base + 2 * gap]
        if r.chance(0.5) { phases.swapAt(0, 2) }
        if r.chance(0.3) { phases.swapAt(0, 1) }
        return Palette(a: a, b: b, c: c, d: .init(phases[0], phases[1], phases[2]))
    }
}

struct VizScene {
    var seed: UInt64
    var name = ""
    var v = [Float](repeating: 0, count: slotCount)

    subscript(_ s: Slot) -> Float {
        get { v[s.rawValue] }
        set { v[s.rawValue] = newValue }
    }

    mutating func setPalette(_ p: Palette) {
        self[.palA0] = p.a.x; self[.palA1] = p.a.y; self[.palA2] = p.a.z
        self[.palB0] = p.b.x; self[.palB1] = p.b.y; self[.palB2] = p.b.z
        self[.palC0] = p.c.x; self[.palC1] = p.c.y; self[.palC2] = p.c.z
        self[.palD0] = p.d.x; self[.palD1] = p.d.y; self[.palD2] = p.d.z
    }
}

/// Builds a complete scene from a seed. Scenes start from one of a few
/// "archetypes" so that random parameters land somewhere that looks intentional.
enum SceneGenerator {
    static let archetypes = ["Tunnel", "Smoke", "Vortex", "Classic", "Ripple", "Implode", "Spectrum"]

    static func make(seed: UInt64, settings s: Settings) -> VizScene {
        var r = RNG(s: seed)
        var sc = VizScene(seed: seed)
        // The mood narrows which archetypes can come up.
        let pool: [Int]
        switch s.mood {
        case "classic": pool = [3, 3, 6]
        case "trippy": pool = [0, 2, 4, 5]
        case "chill": pool = [1, 1, 4]
        default: pool = Array(0..<archetypes.count)
        }
        let kind = pool[Int(r.next() % UInt64(pool.count))]
        sc.name = "\(archetypes[kind]) \(String(format: "%04X", UInt16(truncatingIfNeeded: seed)))"

        func on(_ p: Float, _ lo: Float = 0.7, _ hi: Float = 1.0) -> Float { r.chance(p) ? r.range(lo, hi) : 0 }

        // Shared defaults.
        sc[.decay] = r.range(0.935, 0.972)
        sc[.blur] = r.chance(0.5) ? r.range(0.1, 0.45) : 0
        sc[.hueShift] = r.chance(0.6) ? r.range(-1.2, 1.2) : 0
        sc[.zoomCurve] = r.range(-0.2, 0.8)
        sc[.swirlFreq] = r.range(2, 8)
        sc[.warpFreq] = r.range(1.5, 5)
        sc[.warpSpeed] = r.range(0.3, 1.2)
        sc[.rippleFreq] = r.range(6, 18)
        sc[.rotBass] = r.chance(0.4) ? r.range(-1.5, 1.5) : 0
        if r.chance(0.2) { sc[.driftX] = r.range(-1, 1); sc[.driftY] = r.range(-1, 1) }
        sc[.kaleidoRot] = r.chance(0.5) ? r.range(-0.25, 0.25) : 0 // spin speed, rad/s

        sc[.waveMode] = Float(r.next() % 4)
        sc[.waveAmp] = r.range(0.6, 1.4)
        sc[.waveRadius] = r.range(0.3, 0.6)
        sc[.waveThick] = r.range(0.6, 1.8)
        sc[.barsMode] = Float(r.next() % 3)
        sc[.barsCount] = r.pick([24, 32, 48, 64, 96])
        sc[.barsSeg] = r.chance(0.5) ? r.pick([16, 24, 32]) : 0
        sc[.orbCount] = Float(3 + r.next() % 6)
        sc[.orbSpeed] = r.range(0.5, 1.6)
        sc[.orbSpread] = r.range(0.5, 1.1)
        sc[.orbSize] = r.range(0.8, 2.2)
        sc[.plasmaScale] = r.range(1.2, 3.5)
        sc[.plasmaSpeed] = r.range(0.3, 1.2)
        sc[.plasmaLines] = r.range(2, 6)
        sc[.shapeSides] = r.pick([3, 4, 5, 6, 8, 32])
        sc[.shapeCount] = Float(1 + r.next() % 4)
        sc[.shapeSpin] = r.sign() * r.range(0.2, 1.5)
        sc[.shapeSize] = r.range(0.7, 1.3)
        sc[.burstRays] = r.pick([6, 8, 12, 16, 24])
        sc[.palPhase] = r.range(0.02, 0.12) // cycle speed, turns/s
        sc[.palSpread] = r.range(0.3, 1.1)
        sc.setPalette(Palette.random(&r))

        var wave: Float = 0, barsOverlay: Float = 0, barsInk: Float = 0, orbs: Float = 0
        var plasma: Float = 0, shapes: Float = 0, burst: Float = 0, sparks: Float = 0
        var kaleidoChance: Float = 0.3

        switch kind {
        case 0: // Tunnel: everything rushes outward
            sc[.zoom] = r.range(0.9, 2.2); sc[.zoomBass] = r.range(0.8, 2.5); sc[.zoomCurve] = r.range(0.2, 0.9)
            sc[.rot] = r.range(-0.4, 0.4)
            sc[.swirl] = r.chance(0.5) ? r.range(-0.3, 0.3) : 0
            sc[.warpAmp] = r.range(0, 0.5)
            wave = on(0.7); sc[.waveMode] = r.pick([1, 3])
            shapes = on(0.85); burst = on(0.6); sparks = on(0.5); orbs = on(0.3)
        case 1: // Smoke: slow, soft, drifting
            sc[.zoom] = r.range(0.15, 0.5); sc[.zoomBass] = r.range(0.3, 1.0)
            sc[.warpAmp] = r.range(1.2, 2.6)
            sc[.blur] = r.range(0.3, 0.6); sc[.decay] = r.range(0.958, 0.98)
            plasma = on(0.85); orbs = on(0.7); wave = on(0.45); sparks = on(0.3)
            kaleidoChance = 0.25
        case 2: // Vortex: spin and swirl
            sc[.rot] = r.sign() * r.range(0.8, 2.4)
            sc[.swirl] = r.sign() * r.range(0.6, 2.0)
            sc[.zoom] = r.range(0.2, 0.9); sc[.zoomBass] = r.range(0.3, 1.2)
            orbs = on(0.9); wave = on(0.5); sc[.waveMode] = 1
            shapes = on(0.4); sparks = on(0.6)
            kaleidoChance = 0.4
        case 3: // Classic: oscilloscope + equaliser
            sc[.zoom] = r.range(0.3, 0.8); sc[.zoomBass] = r.range(0.5, 1.5)
            sc[.warpAmp] = r.range(0, 0.5); sc[.decay] = r.range(0.93, 0.96)
            wave = r.range(0.85, 1.0); sc[.waveMode] = r.pick([0, 2])
            barsOverlay = on(0.75); burst = on(0.3)
            sc[.barsMode] = r.pick([0, 0, 1])
            kaleidoChance = 0
        case 4: // Ripple: rings travelling through the image
            sc[.ripple] = r.range(1, 3)
            sc[.zoom] = r.range(-0.2, 0.5); sc[.zoomBass] = r.range(0.3, 1.2)
            shapes = on(0.6); plasma = on(0.6); wave = on(0.6); sc[.waveMode] = 1
            orbs = on(0.45)
            kaleidoChance = 0.4
        case 5: // Implode: everything falls into the centre
            sc[.zoom] = -r.range(0.5, 1.4); sc[.zoomBass] = -r.range(0.2, 0.8)
            sc[.rot] = r.sign() * r.range(0.2, 1.0)
            wave = on(0.8); sc[.waveMode] = r.pick([0, 2])
            orbs = on(0.7); sc[.orbSpread] = r.range(0.9, 1.3)
            sparks = on(0.7)
            barsInk = on(0.4); if barsInk > 0 { sc[.barsMode] = 2 }
            kaleidoChance = 0.35
        default: // Spectrum: the equaliser itself paints the trails
            sc[.zoom] = r.range(0.5, 1.3); sc[.zoomBass] = r.range(1.0, 2.0)
            barsInk = r.range(0.8, 1.0)
            sc[.barsMode] = r.pick([2, 2, 2, 1, 0])
            barsOverlay = on(0.5)
            wave = on(0.5); sc[.waveMode] = 3
            burst = on(0.5); shapes = on(0.3)
            kaleidoChance = sc[.barsMode] == 2 ? 0.15 : 0
        }

        switch s.mood {
        case "trippy":
            kaleidoChance = max(kaleidoChance, 0.6)
        case "chill":
            kaleidoChance *= 0.5
            for slot in [Slot.zoom, .zoomBass, .rot, .rotBass, .swirl, .ripple, .palPhase, .orbSpeed, .shapeSpin] {
                sc[slot] *= 0.6
            }
            burst = 0
        case "classic":
            barsOverlay = max(barsOverlay, 0.9)
        default:
            break
        }
        sc[.kaleidoN] = r.chance(kaleidoChance) ? r.pick([3, 4, 5, 6, 8, 10, 12]) : 0

        // Respect the user's layer switches.
        if !s.layerWave { wave = 0 }
        if !s.layerBars { barsOverlay = 0; barsInk = 0 }
        if !s.layerOrbs { orbs = 0 }
        if !s.layerPlasma { plasma = 0 }
        if !s.layerShapes { shapes = 0 }
        if !s.layerBurst { burst = 0 }
        if !s.layerSparks { sparks = 0 }

        // Never hand back an empty scene.
        if wave + barsOverlay + barsInk + orbs + plasma + shapes == 0 {
            if s.layerWave { wave = 1 }
            else if s.layerOrbs { orbs = 1 }
            else if s.layerShapes { shapes = 1 }
            else if s.layerPlasma { plasma = 1 }
            else if s.layerBars { barsOverlay = 1; barsInk = 0.6 }
            else if s.layerSparks { sparks = 1 }
            else if s.layerBurst { burst = 1 }
        }

        sc[.waveAmt] = wave; sc[.barsAmt] = barsOverlay; sc[.barsInk] = barsInk; sc[.orbAmt] = orbs
        sc[.plasmaAmt] = plasma; sc[.shapeAmt] = shapes; sc[.burstAmt] = burst; sc[.sparkAmt] = sparks
        return sc
    }
}

/// Owns the current scene, morphs between scenes and decides when to move on.
final class SceneDirector {
    private(set) var current: VizScene
    private var previous: VizScene
    private var morph: Float = 1
    private var morphDuration: Float = 3
    private var sinceChange: Float = 0
    private var kaleidoAngle: Float = 0
    private var palPhase: Float = 0
    private var flash: Float = 0
    private var rng = RNG(s: UInt64(Date().timeIntervalSince1970 * 1000) ^ 0xC0FFEE)
    private var history: [UInt64] = []
    private var layerSignature = ""

    var onSceneChange: ((VizScene) -> Void)?

    private static let sceneRange = Slot.zoom.rawValue...Slot.palSpread.rawValue
    /// Slots that cannot be blended, with the layer amounts that fade out around their switch.
    private static let discrete: [(Slot, [Slot])] = [
        (.kaleidoN, []),
        (.waveMode, [.waveAmt]),
        (.barsMode, [.barsAmt, .barsInk]),
        (.barsCount, [.barsAmt, .barsInk]),
        (.barsSeg, []),
        (.orbCount, []),
        (.shapeSides, [.shapeAmt]),
        (.shapeCount, []),
        (.burstRays, []),
    ]

    init() {
        let s = Settings()
        current = SceneGenerator.make(seed: 1, settings: s)
        previous = current
    }

    func go(to seed: UInt64, settings: Settings, morphSeconds: Float? = nil, remember: Bool = true) {
        if remember, current.seed != seed { history.append(current.seed); if history.count > 64 { history.removeFirst() } }
        previous = snapshot()
        current = SceneGenerator.make(seed: seed, settings: settings)
        morphDuration = max(0.01, morphSeconds ?? Float(settings.morphSeconds))
        morph = 0
        sinceChange = 0
        flash = 1
        layerSignature = settings.generationSignature
        onSceneChange?(current)
    }

    func next(settings: Settings) {
        go(to: rng.next(), settings: settings)
    }

    func back(settings: Settings) {
        guard let seed = history.popLast() else { return }
        go(to: seed, settings: settings, remember: false)
    }

    func update(dt: Float, beat: Bool, settings s: Settings) {
        if s.generationSignature != layerSignature {
            go(to: current.seed, settings: s, morphSeconds: 0.6, remember: false)
        }
        morph = min(1, morph + dt / morphDuration)
        sinceChange += dt
        flash *= expf(-dt * 4)

        let t = Self.ease(morph)
        let spin = Self.lerp(previous[.kaleidoRot], current[.kaleidoRot], t)
        kaleidoAngle += spin * dt
        let cycle = Self.lerp(previous[.palPhase], current[.palPhase], t)
        palPhase += cycle * Float(s.colorSpeed) * dt
        if palPhase > 64 { palPhase -= 64 }

        if s.autoChange, !s.locked {
            let interval = Float(s.interval)
            if sinceChange > interval, beat || sinceChange > interval + 2 {
                next(settings: s)
            }
        }
    }

    /// Writes the blended scene, with user settings applied, into the uniform array.
    func write(into u: inout [Float], settings s: Settings) {
        let t = Self.ease(morph)
        for i in Self.sceneRange {
            u[i] = Self.lerp(previous.v[i], current.v[i], t)
        }
        for (slot, gated) in Self.discrete {
            let a = previous[slot], b = current[slot]
            u[slot.rawValue] = t < 0.5 ? a : b
            if a != b {
                for g in gated {
                    u[g.rawValue] = t < 0.5 ? previous[g] * (1 - 2 * t) : current[g] * (2 * t - 1)
                }
            }
        }
        u[Slot.kaleidoRot.rawValue] = kaleidoAngle
        u[Slot.palPhase.rawValue] = palPhase
        u[Slot.flash.rawValue] = flash
        u[Slot.seed.rawValue] = Float(current.seed % 1000) * 0.37

        // User overrides.
        let trailFactor = powf(3, 1 - 2 * Float(s.trails))
        u[Slot.decay.rawValue] = min(0.995, max(0.5, 1 - (1 - u[Slot.decay.rawValue]) * trailFactor))
        if s.kaleido == 0 { u[Slot.kaleidoN.rawValue] = 0 }
        else if s.kaleido > 0 { u[Slot.kaleidoN.rawValue] = Float(s.kaleido) }
        if !s.layerWave { u[Slot.waveAmt.rawValue] = 0 }
        if !s.layerBars { u[Slot.barsAmt.rawValue] = 0; u[Slot.barsInk.rawValue] = 0 }
        else if s.alwaysBars { u[Slot.barsAmt.rawValue] = max(u[Slot.barsAmt.rawValue], 1) }
        if !s.layerOrbs { u[Slot.orbAmt.rawValue] = 0 }
        if !s.layerPlasma { u[Slot.plasmaAmt.rawValue] = 0 }
        if !s.layerShapes { u[Slot.shapeAmt.rawValue] = 0 }
        if !s.layerBurst { u[Slot.burstAmt.rawValue] = 0 }
        if !s.layerSparks { u[Slot.sparkAmt.rawValue] = 0 }
        if let p = Palette.preset(s.palette) {
            var tmp = VizScene(seed: 0)
            tmp.setPalette(p)
            for i in Slot.palA0.rawValue...Slot.palD2.rawValue { u[i] = tmp.v[i] }
        }
    }

    /// The scene as currently blended, used as the starting point of the next morph.
    private func snapshot() -> VizScene {
        guard morph < 1 else { return current }
        var out = current
        let t = Self.ease(morph)
        for i in Self.sceneRange { out.v[i] = Self.lerp(previous.v[i], current.v[i], t) }
        for (slot, _) in Self.discrete { out[slot] = t < 0.5 ? previous[slot] : current[slot] }
        return out
    }

    private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    private static func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }
}
