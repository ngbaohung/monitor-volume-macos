import CoreAudio
import Foundation
import Synchronization

/// Software volume for an output device that has no volume control of its own (HDMI/DisplayPort).
///
/// A Core Audio process tap captures everything other apps send to the device and mutes the
/// original while we read it. A private aggregate device (the tap + the real device) then plays
/// the captured audio back to the device with our gain applied. If the app stops or crashes the
/// tap goes away and audio plays unmuted again.
final class SoftwareVolumeEngine: @unchecked Sendable {
    struct EngineError: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "Couldn't \(step) (error \(status))." }
    }

    /// Target linear gain, written from the main thread and read on the audio thread.
    private let targetGain = Atomic<UInt32>(Float(1).bitPattern)
    /// Gain applied at the end of the previous buffer; only touched on the audio thread.
    private var appliedGain: Float = 1

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "MonitorVolume.softwareVolume", qos: .userInteractive)

    private(set) var deviceID: AudioObjectID?
    var isRunning: Bool { procID != nil }

    func setGain(_ gain: Float) {
        targetGain.store(gain.bitPattern, ordering: .relaxed)
    }

    func start(device: AudioDevice) throws {
        stop()
        do {
            try createTap(for: device)
            try createAggregate(for: device)
            appliedGain = Float(bitPattern: targetGain.load(ordering: .relaxed))
            try check("start audio", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [unowned self] _, input, _, output, _ in
                render(input: input, output: output)
            })
            try check("start audio", AudioDeviceStart(aggregateID, procID))
            deviceID = device.id
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        deviceID = nil
    }

    // MARK: Setup

    private var tapUUID = UUID()

    private func createTap(for device: AudioDevice) throws {
        // Tap only audio headed to this device's first stream, excluding our own playback.
        let excluded = AudioOutput.currentProcessObjectID.map { [NSNumber(value: $0)] } ?? []
        let description = CATapDescription(__excludingProcesses: excluded, andDeviceUID: device.uid, withStream: 0)
        description.name = "Monitor Volume"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        tapUUID = description.uuid
        try check("capture system audio", AudioHardwareCreateProcessTap(description, &tapID))
    }

    private func createAggregate(for device: AudioDevice) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Monitor Volume",
            kAudioAggregateDeviceUIDKey: AudioOutput.privateDeviceUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check("create the audio route", AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID))
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw EngineError(step: step, status: status) }
    }

    // MARK: Audio thread

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let target = Float(bitPattern: targetGain.load(ordering: .relaxed))
        let start = appliedGain

        for index in 0..<outputs.count {
            let out = outputs[index]
            guard let outData = out.mData else { continue }
            let dst = outData.assumingMemoryBound(to: Float.self)
            let outSamples = Int(out.mDataByteSize) / MemoryLayout<Float>.size

            guard index < inputs.count, let inData = inputs[index].mData else {
                dst.update(repeating: 0, count: outSamples)
                continue
            }
            // The tap's format matches the device stream it taps, so channel layouts line up.
            let src = inData.assumingMemoryBound(to: Float.self)
            let samples = min(outSamples, Int(inputs[index].mDataByteSize) / MemoryLayout<Float>.size)
            let channels = max(Int(out.mNumberChannels), 1)
            let frames = samples / channels

            // Ramp across the buffer so volume changes don't click.
            for frame in 0..<frames {
                let gain = start + (target - start) * Float(frame + 1) / Float(max(frames, 1))
                for channel in 0..<channels {
                    let i = frame * channels + channel
                    dst[i] = src[i] * gain
                }
            }
            if frames * channels < outSamples {
                (dst + frames * channels).update(repeating: 0, count: outSamples - frames * channels)
            }
        }
        appliedGain = target
    }
}
