import CoreAudio
import Foundation
import Synchronization

/// Measures how loud each app actually is, so a paused player that keeps its audio
/// stream open (Safari, Music…) isn't shown as playing.
///
/// One private aggregate device holds an unmuted tap per app and no hardware at all,
/// so it never wakes up an output device or a headset's microphone. Its IOProc only
/// records each tap's peak level; the main thread reads and resets the peaks.
final class LevelMonitor {
    let keys: [String]
    private var taps: [AudioObjectID] = []
    private var aggregateID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let meters: [PeakMeter]

    init(groups: [(key: String, processes: [AudioObjectID])]) throws {
        keys = groups.map(\.key)
        meters = groups.map { _ in PeakMeter() }
        do {
            try start(groups)
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    /// Peak level per app since the last call (0…1).
    func takePeaks() -> [String: Float] {
        var peaks: [String: Float] = [:]
        for (key, meter) in zip(keys, meters) {
            peaks[key] = Float(bitPattern: meter.bits.exchange(0, ordering: .relaxed))
        }
        return peaks
    }

    private func start(_ groups: [(key: String, processes: [AudioObjectID])]) throws {
        var tapList: [[String: Any]] = []
        var buffersPerTap = 1
        for group in groups {
            let description = CATapDescription(stereoMixdownOfProcesses: group.processes)
            description.uuid = UUID()
            description.name = "Volumist Level"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            var tap = AudioObjectID.unknown
            try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
            taps.append(tap)
            tapList.append([kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: false])

            if let format = CA.get(tap, CA.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription()),
               format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                buffersPerTap = Int(max(format.mChannelsPerFrame, 1))
            }
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Volumist Levels",
            kAudioAggregateDeviceUIDKey: AudioDevices.privateUIDPrefix + "levels." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        var aggregate = AudioObjectID.unknown
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "AudioHardwareCreateAggregateDevice")
        aggregateID = aggregate

        let meters = self.meters
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            for (index, buffer) in buffers.enumerated() {
                let slot = index / buffersPerTap
                guard slot < meters.count, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                var peak: Float = 0
                for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size {
                    peak = max(peak, abs(data[i]))
                }
                meters[slot].raise(to: peak)
            }
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
        taps.forEach { AudioHardwareDestroyProcessTap($0) }
        taps.removeAll()
        ioProcID = nil
        aggregateID = .unknown
    }
}

private final class PeakMeter: @unchecked Sendable {
    let bits = Atomic<UInt32>(0)

    /// Called on the IO thread; keeps the highest value since the last read.
    func raise(to peak: Float) {
        var current = bits.load(ordering: .relaxed)
        while peak > Float(bitPattern: current) {
            let (exchanged, original) = bits.compareExchange(expected: current, desired: peak.bitPattern, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
    }
}
