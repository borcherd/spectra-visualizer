import Foundation
import Metal
import CoreGraphics
import ImageIO

/// Headless test mode: `Spectra --snapshot out.png [--scenes 9] [--frames 420]
/// [--seed 1] [--size 640x360] [--cols 3]`. Renders several random scenes off
/// screen against the built-in demo groove and writes them as one contact sheet.
enum Snapshot {
    static func run(_ args: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let outPath = value("--snapshot") ?? "snapshot.png"
        let scenes = Int(value("--scenes") ?? "") ?? 9
        let frames = Int(value("--frames") ?? "") ?? 420
        let seed = UInt64(value("--seed") ?? "") ?? 1
        let cols = Int(value("--cols") ?? "") ?? 3
        var width = 640, height = 360
        if let size = value("--size")?.split(separator: "x"), size.count == 2,
           let w = Int(size[0]), let h = Int(size[1]) { width = w; height = h }

        guard let device = MTLCreateSystemDefaultDevice() else {
            FileHandle.standardError.write("No Metal device\n".data(using: .utf8)!)
            return 1
        }
        let analyzer = AudioAnalyzer()
        let director = SceneDirector()
        let renderer: Renderer
        do {
            renderer = try Renderer(device: device, analyzer: analyzer, director: director)
        } catch {
            FileHandle.standardError.write("Renderer failed: \(error)\n".data(using: .utf8)!)
            return 1
        }

        var s = Settings()
        s.demoMode = true
        s.autoChange = false
        s.resolution = 1
        s.grain = 0
        if let k = value("--kaleido"), let n = Int(k) { s.kaleido = n }
        if let p = value("--palette") { s.palette = p }
        if args.contains("--bars") { s.alwaysBars = true }
        if let m = value("--mood") { s.mood = m }
        if args.contains("--auto-res") { s.resolution = 0 }
        // `--resize-to WxH`: after the normal frames, switch to a target of another
        // size for two frames, as happens when the window moves to another screen.
        var resizeTarget: MTLTexture?
        if let size = value("--resize-to")?.split(separator: "x"), size.count == 2,
           let w = Int(size[0]), let h = Int(size[1]) {
            let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.outputFormat, width: w, height: h, mipmapped: false)
            rd.usage = [.renderTarget, .shaderRead]
            rd.storageMode = .shared
            resizeTarget = device.makeTexture(descriptor: rd)
        }

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.outputFormat, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let target = device.makeTexture(descriptor: td) else { return 1 }

        let rows = (scenes + cols - 1) / cols
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        // `--icon` clips the result to a macOS-style rounded square on a transparent canvas.
        let icon = args.contains("--icon")
        let sheetInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let sheet = CGContext(data: nil, width: cols * width, height: rows * height, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: cs, bitmapInfo: sheetInfo) else { return 1 }
        let full = CGRect(x: 0, y: 0, width: cols * width, height: rows * height)
        if icon {
            let inset = full.insetBy(dx: full.width * 0.098, dy: full.height * 0.098)
            sheet.addPath(CGPath(roundedRect: inset, cornerWidth: inset.width * 0.225, cornerHeight: inset.width * 0.225, transform: nil))
            sheet.clip()
        } else {
            sheet.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            sheet.fill(full)
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var clock: CFTimeInterval = 1000
        let dt: Float = 1.0 / 60.0
        for k in 0..<scenes {
            director.go(to: seed &+ UInt64(k), settings: s, morphSeconds: 0.01, remember: false)
            print("[\(k)] \(director.current.name)")
            for f in 0..<frames {
                clock += Double(dt)
                renderer.step(dt: dt, settings: s, now: clock)
                guard let cb = renderer.makeCommandBuffer() else { return 1 }
                renderer.encode(to: target, commandBuffer: cb, settings: s)
                cb.commit()
                if f % 30 == 29 || f == frames - 1 { cb.waitUntilCompleted() }
            }
            if let rt = resizeTarget {
                for _ in 0..<2 {
                    clock += Double(dt)
                    renderer.step(dt: dt, settings: s, now: clock)
                    guard let cb = renderer.makeCommandBuffer() else { return 1 }
                    renderer.encode(to: rt, commandBuffer: cb, settings: s)
                    cb.commit()
                    cb.waitUntilCompleted()
                }
                // Render back at the sheet size so the result fits the contact sheet.
                clock += Double(dt)
                renderer.step(dt: dt, settings: s, now: clock)
                guard let cb = renderer.makeCommandBuffer() else { return 1 }
                renderer.encode(to: target, commandBuffer: cb, settings: s)
                cb.commit()
                cb.waitUntilCompleted()
            }
            pixels.withUnsafeMutableBytes { raw in
                target.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
                CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                          bytesPerRow: width * 4, space: cs, bitmapInfo: info)?.makeImage()
            }
            if let image {
                let col = k % cols, row = k / cols
                sheet.draw(image, in: CGRect(x: col * width, y: (rows - 1 - row) * height, width: width, height: height))
            }
        }

        guard let out = sheet.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, "public.png" as CFString, 1, nil)
        else { return 1 }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { return 1 }
        print("Wrote \(outPath)")
        return 0
    }
}
