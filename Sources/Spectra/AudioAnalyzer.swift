import Foundation
import Accelerate
import QuartzCore
import os

/// Turns raw samples into what the visuals need: a log-frequency spectrum,
/// peak-hold caps, a stabilised waveform, band levels and beat pulses.
final class AudioAnalyzer {
    static let bins = 512
    static let fftN = 2048
    static let texRows = 4

    // Ring buffer shared with the audio thread.
    private let ringSize = 16384
    private let ring: UnsafeMutablePointer<Float>
    private var writeIdx = 0
    private var lastPush: CFTimeInterval = 0
    private let lock = OSAllocatedUnfairLock()

    var acceptTap = true
    var sampleRate: Double = 48000 { didSet { if sampleRate != oldValue { rebuildMap() } } }

    // FFT state.
    private let log2n = vDSP_Length(11)
    private let fft: FFTSetup
    private let frameLen = 2560
    private var frame: [Float]
    private var window: [Float]
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var mags: [Float]
    private var amps: [Float]
    private var binPos = [Float](repeating: 0, count: bins + 1)
    private var binTilt = [Float](repeating: 0, count: bins)

    // Outputs (read on the render thread only).
    private(set) var spectrum = [Float](repeating: 0, count: bins)
    private(set) var peaks = [Float](repeating: 0, count: bins)
    private var peakHold = [Float](repeating: 0, count: bins)
    private(set) var wave = [Float](repeating: 0, count: bins)
    private(set) var texData = [UInt16](repeating: 0, count: bins * texRows)

    private(set) var bass: Float = 0
    private(set) var mid: Float = 0
    private(set) var treble: Float = 0
    private(set) var level: Float = 0
    private(set) var beat: Float = 0
    private(set) var beatTriggered = false
    private(set) var bassAccum: Float = 0
    private(set) var silentFor: Float = 0

    // Auto gain.
    private var bassMax: Float = 1e-3
    private var midMax: Float = 1e-3
    private var trebleMax: Float = 1e-3
    private var specMax: Float = 0.3
    private var ampMax: Float = 0.05
    private var bassAvg: Float = 0
    private var sinceBeat: Float = 1

    init() {
        ring = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
        ring.initialize(repeating: 0, count: ringSize)
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        let n = Self.fftN
        frame = [Float](repeating: 0, count: frameLen)
        window = [Float](repeating: 0, count: n)
        windowed = [Float](repeating: 0, count: n)
        realp = [Float](repeating: 0, count: n / 2)
        imagp = [Float](repeating: 0, count: n / 2)
        mags = [Float](repeating: 0, count: n / 2)
        amps = [Float](repeating: 0, count: n / 2)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        rebuildMap()
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
        ring.deallocate()
    }

    private func rebuildMap() {
        let fMin: Float = 32, fMax: Float = 16000
        let hz = Float(sampleRate) / Float(Self.fftN)
        for i in 0...Self.bins {
            let f = fMin * powf(fMax / fMin, Float(i) / Float(Self.bins))
            binPos[i] = min(f / hz, Float(Self.fftN / 2 - 2))
            if i < Self.bins { binTilt[i] = 4.0 * log2f(f / 1000) }
        }
    }

    // MARK: - Input

    func pushFromTap(_ p: UnsafePointer<Float>, _ n: Int) {
        guard acceptTap else { return }
        push(p, n)
    }

    func push(_ p: UnsafePointer<Float>, _ n: Int) {
        let now = CACurrentMediaTime()
        lock.lock()
        var w = writeIdx
        for i in 0..<n {
            ring[w] = p[i]
            w += 1
            if w == ringSize { w = 0 }
        }
        writeIdx = w
        lastPush = now
        lock.unlock()
    }

    // MARK: - Per-frame analysis

    func update(dt: Float, sensitivity: Float, smoothing: Float, now: CFTimeInterval = CACurrentMediaTime()) {
        let n = Self.fftN
        let half = n / 2

        // Latest samples (or silence if the stream stalled).
        lock.lock()
        let stale = now - lastPush > 0.3
        var r = (writeIdx - frameLen + ringSize) % ringSize
        for i in 0..<frameLen {
            frame[i] = stale ? 0 : ring[r]
            r += 1
            if r == ringSize { r = 0 }
        }
        lock.unlock()

        // Level + silence tracking.
        var rms: Float = 0
        var peakAmp: Float = 0
        frame.withUnsafeBufferPointer { fp in
            vDSP_rmsqv(fp.baseAddress! + (frameLen - n), 1, &rms, vDSP_Length(n))
            vDSP_maxmgv(fp.baseAddress! + (frameLen - n), 1, &peakAmp, vDSP_Length(n))
        }
        if rms < 1e-5 { silentFor += dt } else { silentFor = 0 }
        ampMax = max(ampMax * expf(-dt / 6), peakAmp, 0.02)

        // FFT of the newest 2048 samples.
        frame.withUnsafeBufferPointer { fp in
            vDSP_vmul(fp.baseAddress! + (frameLen - n), 1, window, 1, &windowed, 1, vDSP_Length(n))
        }
        windowed.withUnsafeBufferPointer { wp in
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                }
            }
        }
        // Normalise so a full-scale sine reads ~1.0.
        var count = Int32(half)
        vvsqrtf(&amps, mags, &count)
        var scale = 1 / Float(n)
        vDSP_vsmul(amps, 1, &scale, &amps, 1, vDSP_Length(half))

        // Bands (linear amplitude), auto-gained.
        let hz = Float(sampleRate) / Float(n)
        func bandMean(_ lo: Float, _ hi: Float) -> Float {
            let a = max(1, Int(lo / hz)), b = min(half - 1, max(a + 1, Int(hi / hz)))
            var m: Float = 0
            amps.withUnsafeBufferPointer { vDSP_meanv($0.baseAddress! + a, 1, &m, vDSP_Length(b - a)) }
            return m
        }
        let bRaw = bandMean(35, 150)
        let mRaw = bandMean(150, 2000)
        let tRaw = bandMean(2000, 12000)
        let slow = expf(-dt / 10)
        bassMax = max(bassMax * slow, bRaw, 1e-4)
        midMax = max(midMax * slow, mRaw, 1e-4)
        trebleMax = max(trebleMax * slow, tRaw, 1e-4)

        func follow(_ cur: Float, _ target: Float) -> Float {
            let rate: Float = target > cur ? 28 : 7
            return cur + (target - cur) * min(1, dt * rate)
        }
        bass = follow(bass, min(1.5, bRaw / bassMax * sensitivity))
        mid = follow(mid, min(1.5, mRaw / midMax * sensitivity))
        treble = follow(treble, min(1.5, tRaw / trebleMax * sensitivity))
        level = follow(level, min(1.5, rms / max(ampMax, 0.02) * 2.2 * sensitivity))
        bassAccum += bass * dt

        // Beat: bass energy jumping above its recent average.
        sinceBeat += dt
        bassAvg += (bRaw - bassAvg) * (1 - expf(-dt / 0.8))
        beatTriggered = false
        if bRaw > bassAvg * 1.35, bRaw > bassMax * 0.3, sinceBeat > 0.2 {
            beatTriggered = true
            sinceBeat = 0
            beat = 1
        } else {
            beat *= expf(-dt * 5.5)
        }

        // Log-frequency display spectrum with attack/release smoothing and peak hold.
        var frameMax: Float = 0
        let release = 0.45 + (1 - smoothing) * 3.0
        for i in 0..<Self.bins {
            let lo = binPos[i], hi = binPos[i + 1]
            var a: Float
            if hi - lo < 1 {
                let c = (lo + hi) * 0.5
                let j = Int(c)
                let f = c - Float(j)
                a = amps[j] * (1 - f) + amps[j + 1] * f
            } else {
                a = 0
                var j = Int(lo)
                let end = Int(hi)
                while j <= end { a = max(a, amps[j]); j += 1 }
            }
            let db = 20 * log10f(a + 1e-9) + binTilt[i]
            let v = max(0, (db + 72) / 60)
            frameMax = max(frameMax, v)
            mags[i] = v // reuse as scratch (bins <= half)
        }
        specMax = max(specMax - dt * 0.03, frameMax, 0.3)
        let gain = 0.92 / specMax * min(sensitivity, 2)
        for i in 0..<Self.bins {
            let target = min(1, mags[i] * gain)
            var cur = spectrum[i]
            if target > cur { cur += (target - cur) * min(1, dt * 32) } else { cur = max(target, cur - dt * release) }
            spectrum[i] = cur
            if cur >= peaks[i] {
                peaks[i] = cur
                peakHold[i] = 0.35
            } else if peakHold[i] > 0 {
                peakHold[i] -= dt
            } else {
                peaks[i] = max(cur, peaks[i] - dt * 0.45)
            }
        }

        // Waveform, aligned to a rising zero crossing so it stands still.
        let waveLen = 1024
        var start = frameLen - waveLen
        var i = start
        while i > 8 {
            if frame[i - 1] < 0, frame[i] >= 0, frame[i - 8] < 0, frame[i + 8] > 0 { start = i; break }
            i -= 1
        }
        let wGain = 0.8 / max(ampMax, 0.02)
        for k in 0..<Self.bins {
            let s = (frame[start + k * 2] + frame[start + k * 2 + 1]) * 0.5
            wave[k] = max(-1, min(1, s * wGain))
        }

        // Pack rows for the GPU: spectrum, waveform, peaks.
        let b = Self.bins
        for k in 0..<b {
            texData[k] = UInt16(max(0, min(1, spectrum[k])) * 65535)
            texData[b + k] = UInt16((wave[k] * 0.5 + 0.5) * 65535)
            texData[2 * b + k] = UInt16(max(0, min(1, peaks[k])) * 65535)
        }
    }
}

/// A small built-in groove so the visuals can run (and be tested) with no music playing.
final class DemoSynth {
    private let sr = 48000.0
    private var t = 0.0
    private var kickPhase = 0.0
    private var sawPhase = 0.0
    private var lp: Float = 0
    private var lastNoise: Float = 0
    private var rngState: UInt32 = 0x1234_5678
    private var lastBeat = -1
    private var buf = [Float](repeating: 0, count: 9600)

    func render(seconds: Double, into analyzer: AudioAnalyzer) {
        let n = max(1, min(buf.count, Int((seconds * sr).rounded())))
        let beatLen = 60.0 / 124.0
        let notes: [Double] = [55, 55, 65.41, 49]
        let arp: [Double] = [880, 1108.73, 1318.51, 1760, 1318.51, 1108.73]
        for i in 0..<n {
            let bt = t / beatLen
            let beatIdx = Int(bt)
            let ph = (bt - Double(beatIdx)) * beatLen
            let bar = beatIdx / 4
            if beatIdx != lastBeat { lastBeat = beatIdx; kickPhase = 0 }

            // Kick (sits out one bar in eight).
            let kf = 45 + 120 * exp(-ph * 30)
            kickPhase += 2 * .pi * kf / sr
            let kickOn = bar % 8 != 7
            let kick = kickOn ? sin(kickPhase) * exp(-ph * 6) * 0.8 : 0

            // Hi-hat on sixteenths.
            rngState = rngState &* 1664525 &+ 1013904223
            let noise = Float(rngState >> 8) / Float(1 << 24) * 2 - 1
            let hp = noise - lastNoise
            lastNoise = noise
            let sixteenth = beatLen / 4
            let ph16 = t.truncatingRemainder(dividingBy: sixteenth)
            let step16 = Int(t / sixteenth)
            let hat = Double(hp) * exp(-ph16 * 80) * (step16 % 4 == 2 ? 0.2 : 0.07)

            // Bass saw, ducked by the kick.
            sawPhase += notes[bar % 4] / sr
            let saw = Float(2 * (sawPhase - floor(sawPhase)) - 1)
            lp += (saw - lp) * 0.08
            let bassLine = Double(lp) * 0.3 * (1 - exp(-ph * 10))

            // Pad + arpeggio.
            let pad = (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.18 * t) + sin(2 * .pi * 329.63 * t))
                * 0.04 * (0.6 + 0.4 * sin(2 * .pi * 0.2 * t))
            let eighth = beatLen / 2
            let ph8 = t.truncatingRemainder(dividingBy: eighth)
            let f = arp[Int(t / eighth) % arp.count]
            let pluck = sin(2 * .pi * f * ph8) * exp(-ph8 * 9) * 0.1

            buf[i] = Float(kick + hat + bassLine + pad + pluck) * 0.7
            t += 1 / sr
        }
        buf.withUnsafeBufferPointer { analyzer.push($0.baseAddress!, n) }
    }
}
