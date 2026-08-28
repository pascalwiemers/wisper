import AVFoundation
import CoreAudio

/// Captures microphone input and accumulates 16 kHz mono Float32 samples,
/// the format Parakeet expects.
final class AudioRecorder {
    private var engine = AVAudioEngine()
    private var needsRebuild = false
    private var configObserver: NSObjectProtocol?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    /// Called on the main queue with the current speech level (0…1) while recording.
    var onLevel: ((Float) -> Void)?

    /// AirPods and other Bluetooth mics drop into low-quality HFP mode when
    /// recording; the Mac's built-in mic array is almost always better.
    var preferBuiltInMic = true

    // Auto-gain state for the level meter: the waveform normalizes against
    // the speaker's actual dynamic range instead of a fixed scale.
    private var noiseFloor: Float = 0.004
    private var recentPeak: Float = 0.04

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Allocates audio resources ahead of time so the first real start is fast.
    func prepare() {
        _ = engine.inputNode.inputFormat(forBus: 0)
        engine.prepare()
        // Audio devices coming/going (AirPods, virtual devices like
        // BlackHole, an iPhone mic) can leave a long-lived engine stale and
        // silently recording nothing. Rebuild on any configuration change.
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
            ) { [weak self] _ in
                self?.needsRebuild = true
                wlog("recorder: audio configuration changed — engine will rebuild")
            }
        }
    }

    /// Force a fresh engine on the next recording (e.g. after a silent take).
    func forceRebuild() {
        needsRebuild = true
    }

    func start() throws {
        guard !isRecording else { return }
        if needsRebuild {
            needsRebuild = false
            engine = AVAudioEngine()
            _ = engine.inputNode.inputFormat(forBus: 0)
            engine.prepare()
            wlog("recorder: engine rebuilt")
        }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        if preferBuiltInMic, let builtIn = Self.builtInInputDeviceID(), let unit = input.audioUnit {
            var deviceID = builtIn
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr { wlog("recorder: could not select built-in mic (status \(status))") }
        }
        let inputFormat = input.inputFormat(forBus: 0)
        wlog("recorder: capturing from \(currentDeviceName() ?? "?") @ \(Int(inputFormat.sampleRate))Hz \(inputFormat.channelCount)ch")
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "Wisper", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio input device"])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        try engine.start()
        isRecording = true
    }

    /// Copy of the samples captured so far — used for live partial transcripts.
    func snapshotSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock()
        let result = samples
        samples = []
        lock.unlock()
        return result
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData else { return }

        let frames = Int(out.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: frames))
        lock.unlock()

        if let onLevel, frames > 0 {
            var sum: Float = 0
            let data = channel[0]
            for i in 0..<frames { sum += data[i] * data[i] }
            let rms = (sum / Float(frames)).squareRoot()

            // Adaptive normalization: the floor tracks background noise
            // (drops fast, rises slowly), the peak tracks the voice's recent
            // loudness (rises instantly, decays over a few seconds). Level is
            // where the current sample sits inside that live range, so quiet
            // and loud speakers both fill the waveform.
            if rms < noiseFloor {
                noiseFloor = rms
            } else {
                noiseFloor = min(noiseFloor * 1.015 + 0.00002, 0.02)
            }
            recentPeak = max(recentPeak * 0.988, noiseFloor + 0.008)
            if rms > recentPeak { recentPeak = rms }

            let range = max(recentPeak - noiseFloor, 0.001)
            let normalized = max(0, min(1, (rms - noiseFloor) / range))
            // Square root lifts mid-volume speech so the bars look alive.
            let level = normalized.squareRoot()
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    /// Name of the device the engine's input unit is actually bound to.
    private func currentDeviceName() -> String? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &deviceID, &size) == noErr else { return nil }
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr,
              let name else { return "device \(deviceID)" }
        return name.takeRetainedValue() as String
    }

    /// Finds the built-in microphone's CoreAudio device ID, if present.
    private static func builtInInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else { return nil }

        for deviceID in deviceIDs {
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }

            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0 {
                return deviceID
            }
        }
        return nil
    }
}
