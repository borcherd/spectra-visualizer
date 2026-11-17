import Foundation
import CoreAudio
import AudioToolbox

/// Captures everything the Mac is playing through a Core Audio process tap
/// (macOS 14.2+) and hands mono-mixed Float32 samples to `onSamples`.
final class SystemAudioTap {
    struct TapError: Error, CustomStringConvertible {
        let what: String
        let status: OSStatus
        var description: String { "\(what) (error \(status))" }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "spectra.audio.tap", qos: .userInteractive)
    private let control = DispatchQueue(label: "spectra.audio.control", qos: .userInitiated)
    private let scratchCapacity = 16384
    private let scratch: UnsafeMutablePointer<Float>
    private var listenerInstalled = false
    private var restartPending = false

    private(set) var sampleRate: Double = 48000
    private(set) var running = false
    private(set) var lastError: String?

    /// Called on the audio queue with mono samples.
    var onSamples: ((UnsafePointer<Float>, Int) -> Void)?
    /// Called on the main queue after a (re)start attempt.
    var onStateChange: (() -> Void)?

    init() {
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        teardown()
        scratch.deallocate()
    }

    /// Starts (or restarts) capture. Runs off the main thread because macOS can
    /// hold the first call while it shows the permission prompt.
    func start() {
        control.async { [weak self] in
            guard let self else { return }
            self.teardown()
            var failure: String?
            var rate = self.sampleRate
            do {
                rate = try self.startThrowing()
            } catch {
                self.teardown()
                failure = "\(error)"
            }
            DispatchQueue.main.async {
                self.sampleRate = rate
                self.running = failure == nil
                self.lastError = failure
                self.installDeviceListener()
                self.onStateChange?()
            }
        }
    }

    func stop() {
        control.async { [weak self] in self?.teardown() }
        running = false
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Internals

    /// Builds the tap and returns its sample rate.
    private func startThrowing() throws -> Double {
        var rate = 48000.0
        // 1. A global stereo tap of every process's output.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "Spectra"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { throw TapError(what: "Could not create the system audio tap", status: err) }
        tapID = tap

        // 2. Tap stream format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard err == noErr else { throw TapError(what: "Could not read the tap format", status: err) }
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else {
            throw TapError(what: "Unsupported tap audio format", status: 0)
        }
        if asbd.mSampleRate > 0 { rate = asbd.mSampleRate }

        // 3. A private aggregate device that carries the tap, clocked by the current output.
        let outputUID = try Self.defaultOutputUID()
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Spectra Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard err == noErr else { throw TapError(what: "Could not create the capture device", status: err) }
        aggregateID = agg

        // 4. IO callback: mix whatever layout arrives down to mono.
        let scratch = self.scratch
        let cap = scratchCapacity
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { [weak self] _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let first = abl.first, let firstData = first.mData else { return }
            let bufferCount = abl.count
            var frames = 0
            if bufferCount == 1 {
                let ch = max(1, Int(first.mNumberChannels))
                frames = min(Int(first.mDataByteSize) / (4 * ch), cap)
                let src = firstData.assumingMemoryBound(to: Float.self)
                if ch == 1 {
                    scratch.update(from: src, count: frames)
                } else {
                    let inv = 1 / Float(ch)
                    for i in 0..<frames {
                        var s: Float = 0
                        for c in 0..<ch { s += src[i * ch + c] }
                        scratch[i] = s * inv
                    }
                }
            } else {
                frames = min(Int(first.mDataByteSize) / 4, cap)
                for i in 0..<frames { scratch[i] = 0 }
                var used: Float = 0
                for b in abl {
                    guard let d = b.mData, Int(b.mDataByteSize) / 4 >= frames else { continue }
                    let src = d.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames { scratch[i] += src[i] }
                    used += 1
                }
                if used > 1 {
                    let inv = 1 / used
                    for i in 0..<frames { scratch[i] *= inv }
                }
            }
            if frames > 0 { self?.onSamples?(UnsafePointer(scratch), frames) }
        }
        guard err == noErr, let proc else { throw TapError(what: "Could not attach the audio callback", status: err) }
        procID = proc

        err = AudioDeviceStart(agg, proc)
        guard err == noErr else { throw TapError(what: "Could not start audio capture", status: err) }
        return rate
    }

    private static func defaultOutputUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard err == noErr, deviceID != kAudioObjectUnknown else {
            throw TapError(what: "No output device found", status: err)
        }
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        err = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw TapError(what: "Could not read the output device", status: err) }
        return uid as String
    }

    /// Rebuild the tap when the user switches speakers / headphones.
    private func installDeviceListener() {
        guard !listenerInstalled else { return }
        listenerInstalled = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            guard let self, !self.restartPending else { return }
            self.restartPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.restartPending = false
                self.start()
            }
        }
    }
}
