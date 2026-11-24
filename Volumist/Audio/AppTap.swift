import CoreAudio
import Foundation
import Synchronization

/// Per-app volume control built on Core Audio process taps (macOS 14.2+).
///
/// The tap captures the app's audio and mutes its normal output. A private
/// aggregate device (tap as input, the real output device as output) runs an
/// IOProc that copies the tapped audio to the speakers with our gain applied.
/// If the IOProc ever stops, the tap stops muting and the app plays normally.
final class AppTap {
    let processObjectIDs: [AudioObjectID]
    let outputDeviceID: AudioObjectID

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let renderer: TapRenderer

    init(processObjectIDs: [AudioObjectID], outputDevice: AudioDevice, gain: Float) throws {
        self.processObjectIDs = processObjectIDs
        self.outputDeviceID = outputDevice.id
        let stereo = AudioDevices.stereoChannels(outputDevice.id)
        renderer = TapRenderer(gain: gain, left: stereo.left, right: stereo.right)

        do {
            try start(outputDevice: outputDevice)
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }


    func setGain(_ gain: Float) {
        renderer.targetGain.store(gain.bitPattern, ordering: .relaxed)
    }

    private func start(outputDevice: AudioDevice) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "Volumist"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        guard let format = CA.get(tap, CA.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription()),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, context: "Unsupported tap format")
        }
        renderer.tapChannels = Int(max(format.mChannelsPerFrame, 1))
        renderer.tapInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        // Input streams the output device itself contributes to the aggregate (e.g. a USB
        // headset's mic). The tap's stream(s) come after these.
        renderer.deviceInputStreams = CA.getArray(
            outputDevice.id, CA.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput), zero: AudioObjectID.unknown
        ).count

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Volumist Tap",
            kAudioAggregateDeviceUIDKey: AudioDevices.privateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDevice.uid,
            kAudioAggregateDeviceClockDeviceKey: outputDevice.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDevice.uid],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ],
            ],
        ]
        var aggregate = AudioObjectID.unknown
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate), "AudioHardwareCreateAggregateDevice")
        aggregateID = aggregate

        let renderer = self.renderer
        var procID: AudioDeviceIOProcID?
        // nil queue: the block runs directly on the HAL's real-time IO thread.
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, _, output, _ in
            renderer.render(input: input, output: output)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID

        try check(AudioDeviceStart(aggregate, procID), "AudioDeviceStart")
    }

    func invalidate() {
        if aggregateID != .unknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
    }
}

/// State shared with the real-time thread. Nothing in `render` allocates or locks.
private final class TapRenderer: @unchecked Sendable {
    let targetGain: Atomic<UInt32>
    private var currentGain: Float
    let left: Int
    let right: Int
    var tapChannels = 2
    var tapInterleaved = true
    var deviceInputStreams = 0

    init(gain: Float, left: Int, right: Int) {
        targetGain = Atomic(gain.bitPattern)
        currentGain = gain
        self.left = left
        self.right = right
    }


    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let tapBufferCount = tapInterleaved ? 1 : tapChannels
        guard inputs.count >= tapBufferCount, tapBufferCount > 0 else { return }
        let first = inputs.count - tapBufferCount >= deviceInputStreams ? deviceInputStreams : inputs.count - tapBufferCount

        // Source samples (left / right) from the tap.
        let leftIn: UnsafeMutablePointer<Float>
        let rightIn: UnsafeMutablePointer<Float>
        let inStride: Int
        let inFrames: Int
        if tapInterleaved {
            let buffer = inputs[first]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let channels = max(Int(buffer.mNumberChannels), 1)
            leftIn = data
            rightIn = channels > 1 ? data + 1 : data
            inStride = channels
            inFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        } else {
            guard let l = inputs[first].mData?.assumingMemoryBound(to: Float.self) else { return }
            let r = tapChannels > 1 ? inputs[first + 1].mData?.assumingMemoryBound(to: Float.self) : l
            leftIn = l
            rightIn = r ?? l
            inStride = 1
            inFrames = Int(inputs[first].mDataByteSize) / MemoryLayout<Float>.size
        }

        // Find where the device's stereo pair lives among the output buffers.
        var lBuffer = -1, lChannel = 0, lStride = 1
        var rBuffer = -1, rChannel = 0, rStride = 1
        var base = 0
        for (index, buffer) in outputs.enumerated() {
            let channels = Int(buffer.mNumberChannels)
            if left >= base, left < base + channels { lBuffer = index; lChannel = left - base; lStride = channels }
            if right >= base, right < base + channels { rBuffer = index; rChannel = right - base; rStride = channels }
            base += channels
        }
        if lBuffer < 0 {
            guard outputs.count > 0, outputs[0].mNumberChannels > 0 else { return }
            lBuffer = 0; lChannel = 0; lStride = Int(outputs[0].mNumberChannels)
        }
        if rBuffer < 0 { rBuffer = lBuffer; rChannel = lChannel; rStride = lStride }

        guard let leftOut = outputs[lBuffer].mData?.assumingMemoryBound(to: Float.self),
              let rightOut = outputs[rBuffer].mData?.assumingMemoryBound(to: Float.self) else { return }
        let lFrames = Int(outputs[lBuffer].mDataByteSize) / (MemoryLayout<Float>.size * lStride)
        let rFrames = Int(outputs[rBuffer].mDataByteSize) / (MemoryLayout<Float>.size * rStride)
        let frames = min(inFrames, lFrames, rFrames)
        guard frames > 0 else { return }

        // Ramp the gain across the buffer to avoid zipper noise while dragging.
        let target = Float(bitPattern: targetGain.load(ordering: .relaxed))
        var gain = currentGain
        let step = (target - gain) / Float(frames)
        let mono = lBuffer == rBuffer && lChannel == rChannel

        for frame in 0..<frames {
            gain += step
            let l = leftIn[frame * inStride] * gain
            let r = rightIn[frame * inStride] * gain
            if mono {
                leftOut[frame * lStride + lChannel] = (l + r) * 0.5
            } else {
                leftOut[frame * lStride + lChannel] = l
                rightOut[frame * rStride + rChannel] = r
            }
        }
        currentGain = target
    }
}
