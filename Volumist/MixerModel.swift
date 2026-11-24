import AppKit
import Combine
import CoreAudio
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "app.volumist.Volumist", category: "Mixer")

struct AppAudio: Identifiable {
    let id: String
    var name: String
    var icon: NSImage
    var processObjectIDs: [AudioObjectID]
    var isPlaying: Bool
    var volume: Double
    var isMuted: Bool
}

struct DeviceState {
    let direction: AudioDirection
    var devices: [AudioDevice] = []
    var selectedID: AudioObjectID = .unknown
    var volume: Double = 0
    var muted = false
    var volumeSettable = false

    var selected: AudioDevice? { devices.first { $0.id == selectedID } }
}

struct AppSetting: Codable, Equatable {
    var volume: Double = 1
    var muted = false

    var isDefault: Bool { self == AppSetting() }
    /// Perceptual taper: slider position → linear gain.
    var gain: Float { muted ? 0 : Float(volume * volume) }
}

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var apps: [AppAudio] = []
    @Published private(set) var output = DeviceState(direction: .output)
    @Published private(set) var input = DeviceState(direction: .input)
    @Published private(set) var permission: AudioCapturePermission = .unknown
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private static let settingsKey = "appSettings"
    private var settings: [String: AppSetting] = [:]
    /// Apps that have played audio this session stay listed while they have an audio client.
    private var seen: Set<String> = []
    private var latest: [String: AppAudio] = [:]
    private var taps: [String: AppTap] = [:]
    private var requestingPermission = false
    private var refreshPending = false

    private var systemListeners: [PropertyListener] = []
    private var processListeners: [AudioObjectID: PropertyListener] = [:]
    private var deviceListeners: [AudioDirection: [PropertyListener]] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) {
            settings = saved
        }
        permission = AudioCapturePermission.current

        systemListeners = [
            PropertyListener(.system, AudioProcesses.listAddress) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            },
            PropertyListener(.system, CA.address(kAudioHardwarePropertyDevices)) { [weak self] in
                MainActor.assumeIsolated { self?.refreshDevices() }
            },
            PropertyListener(.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
                MainActor.assumeIsolated { self?.defaultDeviceChanged(.output) }
            },
            PropertyListener(.system, CA.address(kAudioHardwarePropertyDefaultInputDevice)) { [weak self] in
                MainActor.assumeIsolated { self?.defaultDeviceChanged(.input) }
            },
        ]

        refreshDevices()
        defaultDeviceChanged(.output)
        defaultDeviceChanged(.input)
        refreshApps()
    }

    func shutdown() {
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
    }

    /// Called whenever the menu opens.
    func menuWillOpen() {
        let current = AudioCapturePermission.current
        if current != .unknown, current != permission {
            permission = current
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshVolume(.output)
        refreshVolume(.input)
        refreshApps()
    }

    // MARK: - Apps

    func setVolume(_ volume: Double, for appID: String) {
        var setting = settings[appID] ?? AppSetting()
        setting.volume = min(max(volume, 0), 1)
        if setting.volume > 0 { setting.muted = false }
        update(setting, for: appID)
    }

    func toggleMute(for appID: String) {
        var setting = settings[appID] ?? AppSetting()
        setting.muted.toggle()
        if !setting.muted, setting.volume == 0 { setting.volume = 0.5 }
        update(setting, for: appID)
    }

    private func update(_ setting: AppSetting, for appID: String) {
        settings[appID] = setting.isDefault ? nil : setting
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        if let index = apps.firstIndex(where: { $0.id == appID }) {
            apps[index].volume = setting.volume
            apps[index].isMuted = setting.muted
        }
        if let entry = latest[appID] { ensureTap(for: entry) }
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refreshApps()
        }
    }

    private func refreshApps() {
        let processes = AudioProcesses.all()

        // Track start/stop of each process's output so "playing" state stays live.
        let ids = Set(processes.map(\.objectID))
        for id in processListeners.keys where !ids.contains(id) { processListeners[id] = nil }
        for id in ids where processListeners[id] == nil {
            processListeners[id] = PropertyListener(id, AudioProcesses.runningOutputAddress) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }

        var grouped: [String: AppAudio] = [:]
        for process in processes {
            guard let app = AudioProcesses.owningApplication(for: process) else { continue }
            let key = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
            if grouped[key] != nil {
                grouped[key]!.processObjectIDs.append(process.objectID)
                grouped[key]!.isPlaying = grouped[key]!.isPlaying || process.isRunningOutput
            } else {
                let setting = settings[key] ?? AppSetting()
                grouped[key] = AppAudio(
                    id: key,
                    name: app.localizedName ?? key,
                    icon: app.icon ?? NSWorkspace.shared.icon(for: .application),
                    processObjectIDs: [process.objectID],
                    isPlaying: process.isRunningOutput,
                    volume: setting.volume,
                    isMuted: setting.muted
                )
            }
        }

        for (key, entry) in grouped where entry.isPlaying { seen.insert(key) }
        latest = grouped
        apps = grouped.values
            .filter { $0.isPlaying || seen.contains($0.id) || settings[$0.id] != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        syncTaps()
    }

    // MARK: - Taps

    private func syncTaps() {
        for key in Array(taps.keys) where latest[key] == nil {
            taps.removeValue(forKey: key)?.invalidate()
        }
        for entry in latest.values where settings[entry.id] != nil || taps[entry.id] != nil {
            ensureTap(for: entry)
        }
    }

    private func ensureTap(for entry: AppAudio) {
        let setting = settings[entry.id] ?? AppSetting()
        let processIDs = entry.processObjectIDs.sorted()

        if let tap = taps[entry.id], tap.processObjectIDs == processIDs, tap.outputDeviceID == output.selectedID {
            tap.setGain(setting.gain)
            return
        }
        // Nothing to do until the user changes something.
        if taps[entry.id] == nil, setting.isDefault { return }

        guard canTap else { return }
        guard let device = output.selected ?? AudioDevices.device(for: output.selectedID, .output) else { return }

        do {
            // Build the replacement before tearing down the old one so the app never blips to full volume.
            let tap = try AppTap(processObjectIDs: processIDs, outputDevice: device, gain: setting.gain)
            taps[entry.id]?.invalidate()
            taps[entry.id] = tap
        } catch {
            log.error("Couldn't tap \(entry.name, privacy: .public): \(String(describing: error), privacy: .public)")
            permission = AudioCapturePermission.current
        }
    }

    private var canTap: Bool {
        switch permission {
        case .authorized:
            return true
        case .denied:
            return false
        case .unknown:
            guard !requestingPermission else { return false }
            requestingPermission = true
            AudioCapturePermission.request { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.requestingPermission = false
                    // If TCC can't be queried at all, let Core Audio handle it.
                    self.permission = result == .unknown ? .authorized : result
                    self.syncTaps()
                }
            }
            return false
        }
    }

    // MARK: - Devices

    func select(_ device: AudioDevice) {
        AudioDevices.setDefault(device)
    }

    func setVolume(_ value: Double, _ direction: AudioDirection) {
        let id = state(direction).selectedID
        guard id != .unknown else { return }
        AudioDevices.setVolume(id, direction, Float(value))
        update(direction) {
            $0.volume = value
            if value > 0 { $0.muted = false }
        }
    }

    func toggleMute(_ direction: AudioDirection) {
        let current = state(direction)
        AudioDevices.setMuted(current.selectedID, direction, !current.muted)
        refreshVolume(direction)
    }

    private func state(_ direction: AudioDirection) -> DeviceState {
        direction == .output ? output : input
    }

    private func update(_ direction: AudioDirection, _ change: (inout DeviceState) -> Void) {
        if direction == .output { change(&output) } else { change(&input) }
    }

    private func refreshDevices() {
        output.devices = AudioDevices.all(.output)
        input.devices = AudioDevices.all(.input)
    }

    private func defaultDeviceChanged(_ direction: AudioDirection) {
        let id = AudioDevices.defaultDeviceID(direction)
        update(direction) { $0.selectedID = id }
        deviceListeners[direction] = [AudioDevices.volumeAddress(direction), AudioDevices.muteAddress(direction)].map { address in
            PropertyListener(id, address) { [weak self] in
                MainActor.assumeIsolated { self?.refreshVolume(direction) }
            }
        }
        refreshVolume(direction)
        // Re-route every tap to the new output.
        if direction == .output { syncTaps() }
    }

    private func refreshVolume(_ direction: AudioDirection) {
        let id = state(direction).selectedID
        update(direction) {
            $0.volumeSettable = AudioDevices.canSetVolume(id, direction)
            $0.volume = Double(AudioDevices.volume(id, direction))
            $0.muted = AudioDevices.isMuted(id, direction)
        }
    }

    // MARK: - Misc

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Launch at login: \(String(describing: error), privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }
}
