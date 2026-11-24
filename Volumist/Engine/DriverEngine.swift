import CoreAudio
import Foundation

/// Swift face of the C engine (VolumistEngine.c) that works with the Volumist audio driver.
///
/// While one exists, the driver publishes the "Volumist" output device. Apps that play to it are
/// mixed by the driver, with each app's gain applied from the rules published here, and the
/// engine plays the mix to the real output device. Nothing is captured, so there's no recording
/// permission and no recording indicator.
@MainActor
final class DriverEngine {
    static let deviceUID = AudioDevices.volumistDeviceUID
    static let driverPath = DriverInstaller.installedURL.path

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: driverPath) }

    /// The Volumist device's ID, once the driver has published it.
    static var deviceID: AudioObjectID? {
        var uid = deviceUID as CFString
        var device = AudioObjectID.unknown
        var address = CA.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != .unknown ? device : nil
    }

    private var engine: OpaquePointer?
    private(set) var outputDeviceID: AudioObjectID = .unknown
    private var activity: NSObjectProtocol?

    init?() {
        guard let engine = ve_create(nil) else { return nil }
        self.engine = engine
        // The heartbeat must keep ticking or the device disappears: keep App Nap away.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Playing the Volumist audio device's mix"
        )
    }

    /// Stops output and removes the shared memory; the Volumist device disappears.
    func shutdown() {
        guard let engine else { return }
        ve_destroy(engine)
        self.engine = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    @discardableResult
    func setOutput(_ device: AudioObjectID) -> Bool {
        guard let engine else { return false }
        let ok = ve_set_output(engine, device) == noErr
        outputDeviceID = ok ? device : .unknown
        return ok
    }

    var isDeviceVisible: Bool { engine.map { ve_device_visible($0) } ?? false }

    struct Rule {
        var pid: pid_t = 0
        var bundleID: String?
        var gain: Float
    }

    func setRules(_ rules: [Rule]) {
        guard let engine else { return }
        ve_rules_begin(engine)
        for rule in rules {
            ve_rules_add(engine, UInt32(max(rule.pid, 0)), rule.bundleID, rule.gain)
        }
        ve_rules_commit(engine)
    }

    var volumeSequence: UInt32 { engine.map { ve_device_volume_sequence($0) } ?? 0 }
    var volume: Float { engine.map { ve_device_volume($0) } ?? 0 }
    var isMuted: Bool { engine.map { ve_device_mute($0) } ?? false }

    func pushVolume(_ volume: Float, muted: Bool) {
        guard let engine else { return }
        ve_push_volume(engine, volume, muted)
    }

    struct Peak {
        let pid: pid_t
        let ownerPID: pid_t
        let level: Float
    }

    func takePeaks() -> [Peak] {
        guard let engine else { return [] }
        var buffer = [VEPeak](repeating: VEPeak(), count: 256)
        let count = buffer.withUnsafeMutableBufferPointer { ve_take_peaks(engine, $0.baseAddress, Int32($0.count)) }
        return buffer.prefix(Int(count)).map { Peak(pid: pid_t($0.pid), ownerPID: pid_t($0.ownerPID), level: $0.peak) }
    }

    var stats: VEStats { engine.map { ve_stats($0) } ?? VEStats() }
}
