import CoreAudio
import Foundation
import Synchronization

/// Gain shared between the main thread and the real-time IO thread.
private final class GainBox: Sendable {
    let bits: Atomic<UInt32>
    init(_ gain: Float) { bits = Atomic(gain.bitPattern) }
    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

/// Taps one app's audio (muting the original) and replays it on `output` with a gain.
///
/// process tap → private aggregate device (main sub-device = output) → IO proc copies tap → output × gain.
final class AppTap {
    let bundleID: String
    let processObjects: [AudioObjectID]
    let output: AudioDevice

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let gainBox: GainBox
    private let ioQueue = DispatchQueue(label: "com.amit.SoundDial.io", qos: .userInteractive)

    var gain: Float {
        get { gainBox.value }
        set { gainBox.value = newValue }
    }

    init(bundleID: String, processObjects: [AudioObjectID], output: AudioDevice, gain: Float) throws {
        self.bundleID = bundleID
        self.processObjects = processObjects
        self.output = output
        self.gainBox = GainBox(gain)
        do {
            try start()
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    private func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "SoundDial \(bundleID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw CoreAudioError(status, "AudioHardwareCreateProcessTap") }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundDial \(bundleID)",
            kAudioAggregateDeviceUIDKey: "com.amit.SoundDial.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { throw CoreAudioError(status, "AudioHardwareCreateAggregateDevice") }
        aggregateID = device

        let box = gainBox
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, ioQueue) { _, input, _, output, _ in
            AppTap.render(input: input, output: output, gain: box.value)
        }
        guard status == noErr else { throw CoreAudioError(status, "AudioDeviceCreateIOProcIDWithBlock") }

        status = AudioDeviceStart(device, procID)
        guard status == noErr else { throw CoreAudioError(status, "AudioDeviceStart") }
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
    }

    /// Real-time: no allocation, no locks. Buffers are Float32 interleaved per stream.
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        // Taps are appended after the sub-device's own input streams, so the tap is the last buffer.
        guard let tapBuffer = inputs.last, let src = tapBuffer.mData?.assumingMemoryBound(to: Float.self) else {
            for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            return
        }
        let inChannels = Int(max(tapBuffer.mNumberChannels, 1))
        let inFrames = Int(tapBuffer.mDataByteSize) / (MemoryLayout<Float>.size * inChannels)

        var totalOutChannels = 0
        for buffer in outputs { totalOutChannels += Int(buffer.mNumberChannels) }

        var channelBase = 0
        for buffer in outputs {
            let outChannels = Int(max(buffer.mNumberChannels, 1))
            defer { channelBase += outChannels }
            guard let dst = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)
            let frames = min(inFrames, outFrames)

            for c in 0..<outChannels {
                let channel = channelBase + c
                var f = 0
                if totalOutChannels == 1 {
                    // Mono output: fold L+R.
                    while f < frames {
                        let l = src[f * inChannels]
                        let r = src[f * inChannels + min(1, inChannels - 1)]
                        dst[f * outChannels + c] = (l + r) * 0.5 * gain
                        f += 1
                    }
                } else if channel < 2 {
                    let sc = min(channel, inChannels - 1)
                    while f < frames {
                        dst[f * outChannels + c] = src[f * inChannels + sc] * gain
                        f += 1
                    }
                }
                while f < outFrames {
                    dst[f * outChannels + c] = 0
                    f += 1
                }
            }
        }
    }
}
