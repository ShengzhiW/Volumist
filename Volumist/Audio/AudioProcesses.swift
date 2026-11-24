import AppKit
import CoreAudio

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
}

enum AudioProcesses {
    static let listAddress = CA.address(kAudioHardwarePropertyProcessObjectList)
    static let runningOutputAddress = CA.address(kAudioProcessPropertyIsRunningOutput)

    private static let ownPID = ProcessInfo.processInfo.processIdentifier
    private static let ownBundleID = Bundle.main.bundleIdentifier ?? "app.volumist.Volumist"

    /// Every process that currently has an audio client in coreaudiod.
    static func all() -> [AudioProcess] {
        CA.getArray(.system, listAddress, zero: AudioObjectID.unknown).compactMap { id in
            guard let pid = CA.get(id, CA.address(kAudioProcessPropertyPID), initial: pid_t(-1)),
                  pid > 0, pid != ownPID else { return nil }
            let bundleID = CA.getString(id, CA.address(kAudioProcessPropertyBundleID))
            let running = (CA.get(id, runningOutputAddress, initial: UInt32(0)) ?? 0) != 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: running)
        }
    }

    /// Maps an audio process to the app the user thinks of as playing it — e.g. Safari for
    /// `com.apple.WebKit.GPU`, or Chrome for "Google Chrome Helper".
    static func owningApplication(for process: AudioProcess) -> NSRunningApplication? {
        // Volumist plays tapped audio itself; never list it (or another copy of it).
        guard let app = resolveApplication(for: process), app.bundleIdentifier != ownBundleID else { return nil }
        return app
    }

    private static func resolveApplication(for process: AudioProcess) -> NSRunningApplication? {
        let direct = NSRunningApplication(processIdentifier: process.pid)
        if let direct, direct.activationPolicy == .regular { return direct }

        let responsible = responsiblePID(for: process.pid)
        if responsible > 0, responsible != process.pid, responsible != ownPID,
           let app = NSRunningApplication(processIdentifier: responsible),
           app.activationPolicy != .prohibited {
            return app
        }

        if let bundleID = process.bundleID {
            let match = NSWorkspace.shared.runningApplications.first { app in
                guard app.activationPolicy == .regular, let appID = app.bundleIdentifier else { return false }
                return bundleID.hasPrefix(appID + ".")
            }
            if let match { return match }
        }

        if let direct, direct.activationPolicy == .accessory, direct.bundleURL != nil { return direct }
        return nil
    }

    private typealias ResponsibilityFn = @convention(c) (pid_t) -> pid_t
    private static let responsibilityFn: ResponsibilityFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibilityFn.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t {
        responsibilityFn?(pid) ?? pid
    }
}
