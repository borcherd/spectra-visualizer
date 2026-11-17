import Foundation
import MetalKit
import QuartzCore

enum AudioStatus: Equatable {
    case starting
    case listening
    case silent
    case demo
    case error(String)
}

/// Drives the whole frame: audio analysis -> scene parameters -> GPU passes.
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let analyzer: AudioAnalyzer
    let director: SceneDirector
    private let queue: MTLCommandQueue
    private let synth = DemoSynth()

    private let pFeedback: MTLRenderPipelineState
    private let pBright: MTLRenderPipelineState
    private let pBlurH: MTLRenderPipelineState
    private let pBlurV: MTLRenderPipelineState
    private let pComposite: MTLRenderPipelineState
    private let pCopy: MTLRenderPipelineState

    private var sceneA: MTLTexture?
    private var sceneB: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private let audioTex: MTLTexture
    private var needsClear = true
    /// The picture from before a resize, stretched into the new buffers on the next frame.
    private var carryOver: MTLTexture?

    private var uni = [Float](repeating: 0, count: slotCount)
    private var time: Float = 0
    private var lastFrame: CFTimeInterval = 0
    private var fpsFrames = 0
    private var fpsClock: CFTimeInterval = 0

    /// Settings come from here every frame; reports go back through `onReport`.
    var settingsProvider: () -> Settings = { Settings() }
    var tapErrorProvider: () -> String? = { nil }
    var onReport: ((_ fps: Double, _ status: AudioStatus) -> Void)?

    static let internalFormat: MTLPixelFormat = .rgba16Float
    static let outputFormat: MTLPixelFormat = .bgra8Unorm

    init(device: MTLDevice, analyzer: AudioAnalyzer, director: SceneDirector) throws {
        self.device = device
        self.analyzer = analyzer
        self.director = director
        guard let q = device.makeCommandQueue() else {
            throw NSError(domain: "Spectra", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Metal command queue"])
        }
        queue = q

        let lib = try device.makeLibrary(source: Shaders.source, options: nil)
        func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vs_full")
            d.fragmentFunction = lib.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        pFeedback = try pipeline("fs_feedback", Self.internalFormat)
        pBright = try pipeline("fs_bright", Self.internalFormat)
        pBlurH = try pipeline("fs_blur_h", Self.internalFormat)
        pBlurV = try pipeline("fs_blur_v", Self.internalFormat)
        pComposite = try pipeline("fs_composite", Self.outputFormat)
        pCopy = try pipeline("fs_copy", Self.internalFormat)

        let ad = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm,
                                                          width: AudioAnalyzer.bins,
                                                          height: AudioAnalyzer.texRows,
                                                          mipmapped: false)
        ad.usage = .shaderRead
        ad.storageMode = .shared
        guard let at = device.makeTexture(descriptor: ad) else {
            throw NSError(domain: "Spectra", code: 2, userInfo: [NSLocalizedDescriptionKey: "No audio texture"])
        }
        audioTex = at
        super.init()
    }

    // MARK: - Frame

    /// Advances audio analysis and scene state by `dt` seconds.
    func step(dt: Float, settings s: Settings, now: CFTimeInterval = CACurrentMediaTime()) {
        time += dt
        if s.demoMode {
            analyzer.acceptTap = false
            synth.render(seconds: Double(dt), into: analyzer)
        } else {
            analyzer.acceptTap = true
        }
        // The Energy dial scales sensitivity, brightness and motion together.
        let e = Float(max(0, min(1, s.energy)))
        analyzer.update(dt: dt, sensitivity: Float(s.sensitivity) * (0.75 + 0.5 * e), smoothing: Float(s.smoothing), now: now)
        director.update(dt: dt, beat: analyzer.beatTriggered, settings: s)
        director.write(into: &uni, settings: s)

        func set(_ slot: Slot, _ v: Float) { uni[slot.rawValue] = v }
        set(.time, time)
        set(.dt60, dt * 60)
        set(.bass, analyzer.bass)
        set(.mid, analyzer.mid)
        set(.treble, analyzer.treble)
        set(.level, analyzer.level)
        set(.beat, analyzer.beat)
        set(.bassAccum, analyzer.bassAccum)
        set(.intensity, Float(s.intensity) * (0.7 + 0.6 * e))
        set(.glow, Float(s.glow))
        set(.grain, Float(s.grain))
        set(.vignette, Float(s.vignette))
        set(.chroma, Float(s.chroma))
        set(.scan, Float(s.scanlines))
        set(.mirror, s.mirror ? 1 : 0)
        set(.warpGlobal, Float(s.motion) * (0.45 + 1.1 * e))

        analyzer.texData.withUnsafeBytes { raw in
            audioTex.replace(region: MTLRegionMake2D(0, 0, AudioAnalyzer.bins, AudioAnalyzer.texRows),
                             mipmapLevel: 0,
                             withBytes: raw.baseAddress!,
                             bytesPerRow: AudioAnalyzer.bins * MemoryLayout<UInt16>.size)
        }
    }

    /// Encodes all passes, ending with the composite into `target`.
    func encode(to target: MTLTexture, commandBuffer cb: MTLCommandBuffer, settings s: Settings) {
        ensureTextures(width: target.width, height: target.height, resolution: s.resolution)
        guard let a = sceneA, let b = sceneB, let b0 = bloomA, let b1 = bloomB else { return }
        if needsClear {
            if let old = carryOver {
                pass(cb, target: a, pipeline: pCopy, textures: [old])
            } else {
                clear(cb, a)
            }
            clear(cb, b)
            carryOver = nil
            needsClear = false
        }
        uni[Slot.aspect.rawValue] = Float(target.width) / Float(max(1, target.height))
        uni[Slot.resX.rawValue] = Float(a.width)
        uni[Slot.resY.rawValue] = Float(a.height)

        pass(cb, target: b, pipeline: pFeedback, textures: [a, audioTex])
        pass(cb, target: b0, pipeline: pBright, textures: [b])
        for _ in 0..<2 {
            pass(cb, target: b1, pipeline: pBlurH, textures: [b0])
            pass(cb, target: b0, pipeline: pBlurV, textures: [b1])
        }
        pass(cb, target: target, pipeline: pComposite, textures: [b, audioTex, b0])
        swap(&sceneA, &sceneB)
    }

    func makeCommandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }

    private func pass(_ cb: MTLCommandBuffer, target: MTLTexture, pipeline: MTLRenderPipelineState, textures: [MTLTexture]) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
        uni.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func clear(_ cb: MTLCommandBuffer, _ tex: MTLTexture) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        rp.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
    }

    /// Internal render size for a given output size. `resolution` 0 means automatic:
    /// full detail on ordinary windows, capped at a pixel budget on very large
    /// (4K-6K) screens so the frame rate holds everywhere.
    static func internalSize(width: Int, height: Int, resolution: Double) -> (Int, Int) {
        var scale = resolution
        if scale <= 0 {
            let budget = 3_200_000.0
            scale = min(1, (budget / Double(max(1, width * height))).squareRoot())
        }
        return (max(64, Int(Double(width) * scale)), max(64, Int(Double(height) * scale)))
    }

    private func ensureTextures(width: Int, height: Int, resolution: Double) {
        let (w, h) = Self.internalSize(width: width, height: height, resolution: resolution)
        if let a = sceneA, a.width == w, a.height == h { return }
        func make(_ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.internalFormat, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        if !needsClear { carryOver = sceneA }
        sceneA = make(w, h)
        sceneB = make(w, h)
        bloomA = make(max(16, w / 4), max(16, h / 4))
        bloomB = make(max(16, w / 4), max(16, h / 4))
        needsClear = true
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let s = settingsProvider()
        let wantFPS = s.fpsCap > 0 ? s.fpsCap : (view.window?.screen?.maximumFramesPerSecond ?? 60)
        if view.preferredFramesPerSecond != wantFPS { view.preferredFramesPerSecond = wantFPS }

        let now = CACurrentMediaTime()
        let dt = lastFrame == 0 ? 1.0 / 60.0 : min(1.0 / 15.0, max(1.0 / 480.0, now - lastFrame))
        lastFrame = now

        step(dt: Float(dt), settings: s, now: now)
        guard let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        encode(to: drawable.texture, commandBuffer: cb, settings: s)
        cb.present(drawable)
        cb.commit()

        fpsFrames += 1
        if now - fpsClock >= 0.5 {
            let fps = Double(fpsFrames) / (now - fpsClock)
            fpsFrames = 0
            fpsClock = now
            let status: AudioStatus
            if s.demoMode { status = .demo }
            else if let e = tapErrorProvider() { status = .error(e) }
            else if analyzer.silentFor > 3 { status = .silent }
            else { status = .listening }
            onReport?(fps, status)
        }
    }
}
