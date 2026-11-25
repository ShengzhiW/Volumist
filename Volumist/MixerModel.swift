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
    /// The app the user sees (not the helper process that plays the audio).
    var pid: pid_t = 0
    var bundleURL: URL?
    var processObjectIDs: [AudioObjectID]
    /// The app has an output stream running (it may be paused and playing silence).
    var isPlaying: Bool
    /// The app is actually making sound. Measured while the menu is open.
    var isAudible = false
    var nowPlaying: String?
    var volume: Double
    var isMuted: Bool
}

/// An app for the Settings › Apps list: anything with an audio client, plus apps that are
/// hidden or have saved volume settings even if they aren't running.
struct KnownApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let isRunning: Bool
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
    /// Increments each time the menu opens (restarts one-shot animations like title scrolling).
    @Published private(set) var menuSession = 0
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var knownApps: [KnownApp] = []
    /// Bundle IDs of apps the user hid from the menu. Their volume settings still apply.
    @Published private(set) var hiddenApps: Set<String> = []
    private static let hiddenAppsKey = "hiddenApps"
    /// Devices hidden from the menu, keyed "output:<UID>" / "input:<UID>", with their names
    /// so hidden devices that are unplugged can still be listed in Settings.
    @Published private(set) var hiddenDevices: [String: String] = [:]
    private static let hiddenDevicesKey = "hiddenDevices"

    private static let settingsKey = "appSettings"
    private var settings: [String: AppSetting] = [:]
    /// Apps that have played audio this session stay listed while they have an audio client.
    private var seen: Set<String> = []
    private var latest: [String: AppAudio] = [:]
    private var taps: [String: AppTap] = [:]
    private var requestingPermission = false
    private var refreshPending = false
    private let nowPlaying = NowPlayingMonitor()

    private var menuIsOpen = false
    private var levelMonitor: LevelMonitor?
    private var monitoredProcesses: [String: [AudioObjectID]] = [:]
    private var levelTimer: Timer?
    private var lastHeard: [String: Date] = [:]
    private static let audibleThreshold: Float = 0.0003  // about -70 dB
    private static let audibleHold: TimeInterval = 1.0

    /// Listening mode and battery of connected AirPods, by device UID. Read
    /// while the menu is open.
    @Published private(set) var headphones: [String: AirPodsControls.State] = [:]
    private var headphoneTimer: Timer?

    private var systemListeners: [PropertyListener] = []
    private var processListeners: [AudioObjectID: PropertyListener] = [:]
    private var outputVolumeListeners: [PropertyListener] = []

    init() {
        hiddenApps = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenAppsKey) ?? [])
        hiddenDevices = UserDefaults.standard.dictionary(forKey: Self.hiddenDevicesKey) as? [String: String] ?? [:]
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) {
            settings = saved
        }
        permission = AudioCapturePermission.current
        nowPlaying.onChange = { [weak self] in self?.applyNowPlaying() }

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
        stopLevelMonitoring()
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
        if !menuIsOpen { menuSession += 1 }
        menuIsOpen = true
        refreshHeadphones()
        if headphoneTimer == nil {
            headphoneTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHeadphones() }
            }
        }
        // The status check can't always tell "granted" from "never asked", and doesn't notice
        // a permission turned on later in System Settings. Asking settles both: it answers
        // instantly and silently once the user has decided, and only prompts the first time.
        if permission != .authorized { requestPermission() }
        refreshApps()
        if levelTimer == nil {
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.readLevels() }
            }
        }
    }

    /// Called when the menu closes; level metering only runs while it's visible.
    func menuDidClose() {
        menuIsOpen = false
        stopLevelMonitoring()
        headphoneTimer?.invalidate()
        headphoneTimer = nil
    }

    // MARK: - AirPods

    private func refreshHeadphones() {
        var states: [String: AirPodsControls.State] = [:]
        for device in output.devices {
            if let state = AirPodsControls.state(of: device) { states[device.uid] = state }
        }
        if states != headphones { headphones = states }
    }

    func setListeningMode(_ mode: AirPodsControls.ListeningMode, on device: AudioDevice) {
        AirPodsControls.setListeningMode(mode, on: device)
        headphones[device.uid]?.listeningMode = mode
    }

    // MARK: - Apps

    func setVolume(_ volume: Double, for appID: String) {
        var setting = settings[appID] ?? AppSetting()
        setting.volume = min(max(volume, 0), 1)
        if setting.volume > 0 { setting.muted = false }
        update(setting, for: appID)
    }

    /// Brings the app forward, like clicking it in the Dock (reopens a window if it has none).
    func open(_ app: AppAudio) {
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else {
            NSRunningApplication(processIdentifier: app.pid)?.activate()
        }
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
                    pid: app.processIdentifier,
                    bundleURL: app.bundleURL,
                    processObjectIDs: [process.objectID],
                    isPlaying: process.isRunningOutput,
                    nowPlaying: nowPlaying.titles[key],
                    volume: setting.volume,
                    isMuted: setting.muted
                )
            }
        }

        for (key, entry) in grouped where entry.isPlaying { seen.insert(key) }
        latest = grouped
        apps = grouped.values
            .filter { $0.isPlaying || seen.contains($0.id) || settings[$0.id] != nil }
            .filter { !hiddenApps.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        refreshKnownApps()

        nowPlaying.track(running: Set(grouped.keys))
        syncTaps()
        updateLevelMonitor()
    }

    // MARK: - Levels

    /// Meters every listed app whose output stream is running, while the menu is open.
    private func updateLevelMonitor() {
        guard menuIsOpen, permission == .authorized else {
            levelMonitor?.invalidate()
            levelMonitor = nil
            monitoredProcesses = [:]
            applyAudible()
            return
        }
        let wanted = Dictionary(uniqueKeysWithValues: apps.filter(\.isPlaying).map { ($0.id, $0.processObjectIDs.sorted()) })
        if wanted != monitoredProcesses {
            levelMonitor?.invalidate()
            levelMonitor = nil
            monitoredProcesses = [:]
            if !wanted.isEmpty {
                do {
                    levelMonitor = try LevelMonitor(groups: wanted.map { (key: $0.key, processes: $0.value) })
                    monitoredProcesses = wanted
                } catch {
                    log.error("Level monitor: \(String(describing: error), privacy: .public)")
                }
            }
        }
        applyAudible()
    }

    private func readLevels() {
        guard let levelMonitor else { return }
        let now = Date()
        for (key, peak) in levelMonitor.takePeaks() where peak > Self.audibleThreshold {
            lastHeard[key] = now
        }
        applyAudible()
    }

    private func applyAudible() {
        let now = Date()
        for index in apps.indices {
            let app = apps[index]
            let audible: Bool
            if levelMonitor == nil {
                // Can't measure (menu closed or no permission): trust the stream state.
                audible = app.isPlaying
            } else if monitoredProcesses[app.id] != nil {
                audible = lastHeard[app.id].map { now.timeIntervalSince($0) < Self.audibleHold } ?? false
            } else {
                audible = false
            }
            if app.isAudible != audible { apps[index].isAudible = audible }
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
        levelMonitor?.invalidate()
        levelMonitor = nil
        monitoredProcesses = [:]
        lastHeard = [:]
    }

    // MARK: - Hidden devices

    /// A device row for Settings › Devices; `device` is nil when it isn't connected.
    struct DeviceListing: Identifiable {
        let id: String
        let name: String
        let device: AudioDevice?
    }

    private static func hiddenKey(_ direction: AudioDirection, _ uid: String) -> String {
        "\(direction == .output ? "output" : "input"):\(uid)"
    }

    func isHidden(_ device: AudioDevice) -> Bool {
        hiddenDevices[Self.hiddenKey(device.direction, device.uid)] != nil
    }

    func setHidden(_ hidden: Bool, listing: DeviceListing) {
        hiddenDevices[listing.id] = hidden ? listing.name : nil
        UserDefaults.standard.set(hiddenDevices, forKey: Self.hiddenDevicesKey)
    }

    /// Devices to list in the menu: everything not hidden, plus the device in use.
    func menuDevices(_ direction: AudioDirection) -> [AudioDevice] {
        let current = direction == .output ? output : input
        return current.devices.filter { !isHidden($0) || $0.id == current.selectedID }
    }

    /// Connected devices plus hidden ones that aren't connected right now.
    func deviceListings(_ direction: AudioDirection) -> [DeviceListing] {
        let current = direction == .output ? output : input
        var listings = current.devices.map {
            DeviceListing(id: Self.hiddenKey(direction, $0.uid), name: $0.name, device: $0)
        }
        let connected = Set(listings.map(\.id))
        let prefix = Self.hiddenKey(direction, "")
        for (key, name) in hiddenDevices where key.hasPrefix(prefix) && !connected.contains(key) {
            listings.append(DeviceListing(id: key, name: name, device: nil))
        }
        return listings
    }

    // MARK: - Hidden apps

    func setHidden(_ hidden: Bool, appID: String) {
        if hidden { hiddenApps.insert(appID) } else { hiddenApps.remove(appID) }
        UserDefaults.standard.set(hiddenApps.sorted(), forKey: Self.hiddenAppsKey)
        refreshApps()
    }

    private func refreshKnownApps() {
        var known: [String: KnownApp] = [:]
        for entry in latest.values {
            known[entry.id] = KnownApp(id: entry.id, name: entry.name, icon: entry.icon, isRunning: true)
        }
        // Hidden or adjusted apps that aren't running: look them up on disk.
        for id in hiddenApps.union(settings.keys) where known[id] == nil && !id.hasPrefix("pid:") {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            known[id] = KnownApp(id: id, name: name, icon: NSWorkspace.shared.icon(forFile: url.path), isRunning: false)
        }
        knownApps = known.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    #if DEBUG
    /// For previews and offscreen renders.
    func overrideAppsForPreview(_ apps: [AppAudio]) { self.apps = apps }
    #endif

    private func applyNowPlaying() {
        for index in apps.indices {
            apps[index].nowPlaying = nowPlaying.titles[apps[index].id]
        }
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
            requestPermission()
            return false
        }
    }

    private func requestPermission() {
        guard !requestingPermission else { return }
        requestingPermission = true
        AudioCapturePermission.request { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.requestingPermission = false
                // If TCC can't be queried at all, let Core Audio handle it.
                self.permission = result == .unknown ? .authorized : result
                self.syncTaps()
                self.updateLevelMonitor()
            }
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
        // Only the output has a volume control in the menu.
        guard direction == .output else { return }
        outputVolumeListeners = [AudioDevices.volumeAddress(.output), AudioDevices.muteAddress(.output)].map { address in
            PropertyListener(id, address) { [weak self] in
                MainActor.assumeIsolated { self?.refreshVolume(.output) }
            }
        }
        refreshVolume(.output)
        // Re-route every tap to the new output.
        syncTaps()
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

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

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
