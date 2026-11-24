#if DEBUG
import CoreAudio
import Foundation
import Synchronization

/// `Volumist --self-test <tone.wav> <report.txt>`: plays a tone with afplay, taps it into
/// BlackHole (so nothing is audible), and measures the level that arrives at each gain.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--self-test"), args.count > index + 2 else { return }
        let tone = args[index + 1]
        let reportURL = URL(fileURLWithPath: args[index + 2])
        var report: [String] = []
        func note(_ line: String) { report.append(line); try? report.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8) }

        let semaphore = DispatchSemaphore(value: 0)
        AudioCapturePermission.request { result in note("permission: \(result)"); semaphore.signal() }
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: .now + 0.05) }

        guard let blackHole = AudioDevices.all(.output).first(where: { $0.name.contains("BlackHole") }) else {
            note("FAIL: no BlackHole device"); exit(1)
        }

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.5", tone]
        try? player.run()
        defer { player.terminate() }

        var target: AudioProcess?
        for _ in 0..<60 where target == nil {
            Thread.sleep(forTimeInterval: 0.05)
            target = AudioProcesses.all().first { $0.pid == player.processIdentifier && $0.isRunningOutput }
        }
        guard let target else { note("FAIL: afplay never started output"); exit(1) }

        let meter = Meter()
        let monitor: (tap: AudioObjectID, aggregate: AudioObjectID, proc: AudioDeviceIOProcID?)
        do { monitor = try makeMonitor(on: blackHole, meter: meter) } catch { note("FAIL monitor: \(error)"); exit(1) }
        defer {
            AudioDeviceStop(monitor.aggregate, monitor.proc)
            AudioHardwareDestroyAggregateDevice(monitor.aggregate)
            AudioHardwareDestroyProcessTap(monitor.tap)
        }

        do {
            let tap = try AppTap(processObjectIDs: [target.objectID], outputDevice: blackHole, gain: 1)
            for gain: Float in [1, 0.25, 0] {
                tap.setGain(gain)
                Thread.sleep(forTimeInterval: 0.4)
                meter.reset()
                Thread.sleep(forTimeInterval: 0.6)
                note(String(format: "gain %.2f -> peak %.4f", gain, meter.peak))
            }
            tap.invalidate()
        } catch {
            note("FAIL: \(error)")
        }
        note("done")
        exit(0)
    }
}

/// A non-muting tap on Volumist's own output: whatever our AppTap plays shows up here.
private func makeMonitor(on device: AudioDevice, meter: Meter) throws -> (tap: AudioObjectID, aggregate: AudioObjectID, proc: AudioDeviceIOProcID?) {
    var pid = ProcessInfo.processInfo.processIdentifier
    var me = AudioObjectID.unknown
    var address = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me), "translate pid")
    guard me != .unknown else { throw CoreAudioError(status: -1, context: "no process object for self") }

    let description = CATapDescription(stereoMixdownOfProcesses: [me])
    description.uuid = UUID()
    description.isPrivate = true
    description.muteBehavior = .unmuted
    var tap = AudioObjectID.unknown
    try check(AudioHardwareCreateProcessTap(description, &tap), "monitor tap")

    let aggregate: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Volumist Monitor",
        kAudioAggregateDeviceUIDKey: AudioDevices.privateUIDPrefix + "monitor." + UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey: device.uid,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
    ]
    var aggregateID = AudioObjectID.unknown
    try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "monitor aggregate")
    var proc: AudioDeviceIOProcID?
    try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) { _, input, _, _, _ in meter.measure(input) }, "monitor ioproc")
    try check(AudioDeviceStart(aggregateID, proc), "monitor start")
    return (tap, aggregateID, proc)
}

private final class Meter: @unchecked Sendable {
    private let bits = Atomic<UInt32>(0)
    var peak: Float { Float(bitPattern: bits.load(ordering: .relaxed)) }
    func reset() { bits.store(0, ordering: .relaxed) }

    func measure(_ input: UnsafePointer<AudioBufferList>) {
        var p = peak
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<Int(buffer.mDataByteSize) / 4 { p = max(p, abs(data[i])) }
        }
        bits.store(p.bitPattern, ordering: .relaxed)
    }
}
#endif
