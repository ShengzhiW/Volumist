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
    /// PIDs of the processes that play the app's audio (the app itself and its helpers).
    var processPIDs: [pid_t] = []
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

    /// True while per-app volume runs through the Volumist audio driver instead of taps.
    @Published private(set) var usingDriver = false
    private var driver: DriverEngine?
    private var driverTimer: Timer?
    private var stoppingDriver = false
    /// Which app each audio process belongs to, for matching the driver's per-process levels.
    private var pidToApp: [pid_t: String] = [:]
    private var lastDriverVolumeSequence: UInt32 = 0
    private var lastPushedVolume: Float = -1
    private var lastPushedMute = false
    private var lastPushTime = Date.distantPast
    /// Until then, leave a device the user picked as the system default instead of reclaiming it.
    private var holdDefaultUntil = Date.distantPast
    /// Headphones being taken back from another device, until the Mac has them or time runs out.
    private var takeover: (id: AudioObjectID, deadline: Date)?
    /// When the real output's headphones were first seen playing for another device.
    private var unlinkedSince: Date?
    /// When the mix last moved to another real output. Only sound that starts after this takes
    /// headphones back, so the Mac and an iPhone don't trade them back and forth.
    private var lastRouteChange = Date.distantPast
    /// Runs while there are headphones to take back, so they come back as soon as the Mac plays.
    private var reclaimTimer: Timer?
    private let nowPlayingClaim = NowPlayingClaim()
    /// A switch to hidden headphones is waiting for the Now Playing claim to register.
    private var switchPending = false
    /// After taking hidden headphones, make them the system default for a moment once they
    /// show up (see trackBluetoothLink).
    private var bounceDefault: (id: AudioObjectID, until: Date)?
    /// Per app (menu key): when its sound was last heard, and when its current stretch of sound began.
    private var lastAudible: [String: Date] = [:]
    private var audibleSince: [String: Date] = [:]
    /// Processes that play macOS alert sounds, which never take headphones back.
    private var alertSoundPIDs: [pid_t: Bool] = [:]

    /// Apps whose sound must last this long (seconds) before it takes headphones back, by bundle
    /// ID. Every other app takes them back as soon as it plays.
    @Published private(set) var switchDelays: [String: Double] = [:]
    private static let switchDelaysKey = "switchDelays"
    static let switchDelayChoices: [Double] = [0.5, 1, 2]
    private var workspaceObservers: [NSObjectProtocol] = []
    /// The real output the driver's mix plays to, and whether the engine was running (so a
    /// relaunch after a crash can go back to it instead of macOS's fallback device).
    @Published private(set) var driverStatus = DriverInstaller.status
    @Published private(set) var driverBusy = false
    @Published private(set) var driverError: String?
    private var awaitingAudioRestart = false
    /// The driver didn't respond this session; use audio capture until the user acts in Settings,
    /// Core Audio restarts, or the app relaunches.
    private var driverFailed = false
    private static let realOutputKey = "driverRealOutputUID"
    private static let engineActiveKey = "driverEngineActive"
    /// Outputs the mix has played to, most recent first, for falling back like macOS does.
    private static let outputHistoryKey = "driverOutputHistory"
    private static let takeoverTimeout: TimeInterval = 4
    private static let claimLeadSeconds: TimeInterval = 0.3
    private static let bounceSeconds: TimeInterval = 0.5

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

    private var systemListeners: [PropertyListener] = []
    private var processListeners: [AudioObjectID: PropertyListener] = [:]
    private var outputVolumeListeners: [PropertyListener] = []

    init() {
        hiddenApps = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenAppsKey) ?? [])
        switchDelays = (UserDefaults.standard.dictionary(forKey: Self.switchDelaysKey) as? [String: Double]) ?? [:]
        hiddenDevices = UserDefaults.standard.dictionary(forKey: Self.hiddenDevicesKey) as? [String: String] ?? [:]
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) {
            settings = saved
        }
        permission = AudioCapturePermission.current
        nowPlaying.onChange = { [weak self] in self?.applyNowPlaying() }

        installSystemListeners()

        // After sleep, play to the real output again (its IO may not have come back on its own).
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { self?.reestablishOutput() }
            }
        })

        // A newly launched app gets its saved volume before it makes a sound.
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishRules() }
        })

        refreshDevices()
        defaultDeviceChanged(.output)
        defaultDeviceChanged(.input)
        configureEngine()
    }

    private func installSystemListeners() {
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
            PropertyListener(.system, CA.address(kAudioHardwarePropertyServiceRestarted)) { [weak self] in
                MainActor.assumeIsolated { self?.audioServiceRestarted() }
            },
        ]
    }

    func shutdown() {
        stopDriver()
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
        // The status check can't always tell "granted" from "never asked", and doesn't notice
        // a permission turned on later in System Settings. Asking settles both: it answers
        // instantly and silently once the user has decided, and only prompts the first time.
        if permission != .authorized, driver == nil { requestPermission() }
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
        if driver != nil {
            publishRules()
        } else if let entry = latest[appID] {
            ensureTap(for: entry)
        }
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
        var pids: [pid_t: String] = [:]
        for process in processes {
            guard let app = AudioProcesses.owningApplication(for: process) else { continue }
            let key = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
            pids[process.pid] = key
            pids[app.processIdentifier] = key
            if grouped[key] != nil {
                grouped[key]!.processObjectIDs.append(process.objectID)
                grouped[key]!.processPIDs.append(process.pid)
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
                    processPIDs: [process.pid],
                    isPlaying: process.isRunningOutput,
                    nowPlaying: nowPlaying.titles[key],
                    volume: setting.volume,
                    isMuted: setting.muted
                )
            }
        }

        for (key, entry) in grouped where entry.isPlaying { seen.insert(key) }
        latest = grouped
        pidToApp = pids
        apps = grouped.values
            .filter { $0.isPlaying || seen.contains($0.id) || settings[$0.id] != nil }
            .filter { !hiddenApps.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        refreshKnownApps()

        nowPlaying.track(running: Set(grouped.keys))
        if driver != nil {
            publishRules()
        } else {
            syncTaps()
        }
        updateLevelMonitor()
    }

    // MARK: - Levels

    /// Meters every listed app whose output stream is running, while the menu is open.
    private func updateLevelMonitor() {
        // With the driver, levels come from the driver itself (see readLevels), no taps needed.
        guard driver == nil, menuIsOpen, permission == .authorized else {
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
        let now = Date()
        if driver != nil {
            drainDriverPeaks()
            applyAudible()
            return
        }
        guard let levelMonitor else { return }
        for (key, peak) in levelMonitor.takePeaks() where peak > Self.audibleThreshold {
            lastHeard[key] = now
        }
        applyAudible()
    }

    /// Reads which apps the driver heard since the last call, for the menu's level indicators
    /// and for taking headphones back.
    private func drainDriverPeaks() {
        guard let driver else { return }
        let now = Date()
        for peak in driver.takePeaks() where peak.level > Self.audibleThreshold {
            let owner = peak.ownerPID > 0 ? peak.ownerPID : peak.pid
            if isAlertSoundProcess(peak.pid) || isAlertSoundProcess(owner) { continue }
            let key = pidToApp[peak.pid] ?? pidToApp[peak.ownerPID]
                ?? NSRunningApplication(processIdentifier: owner)?.bundleIdentifier ?? "pid:\(owner)"
            lastHeard[key] = now
            if lastAudible[key].map({ now.timeIntervalSince($0) > Self.stretchGap }) ?? true { audibleSince[key] = now }
            lastAudible[key] = now
        }
    }

    private func isAlertSoundProcess(_ pid: pid_t) -> Bool {
        if let known = alertSoundPIDs[pid] { return known }
        var name = [CChar](repeating: 0, count: 256)
        let isAlerts = proc_name(pid, &name, UInt32(name.count)) > 0
            && Self.alertSoundProcessNames.contains(String(cString: name))
        alertSoundPIDs[pid] = isAlerts
        return isAlerts
    }

    private static let alertSoundProcessNames: Set<String> = ["systemsoundserverd", "SystemSoundServer-macOS"]
    /// An app heard within this long is playing now.
    private static let soundGap: TimeInterval = 0.3
    /// Silence longer than this ends an app's stretch of sound; sound after it is a new start.
    private static let stretchGap: TimeInterval = 1

    private func applyAudible() {
        let now = Date()
        for index in apps.indices {
            let app = apps[index]
            let audible: Bool
            if driver != nil {
                audible = app.isPlaying && (lastHeard[app.id].map { now.timeIntervalSince($0) < Self.audibleHold } ?? false)
            } else if levelMonitor == nil {
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

    // MARK: - Switching delays

    /// Sets how long `appID` must play before it takes headphones back; nil removes the delay.
    func setSwitchDelay(_ seconds: Double?, appID: String) {
        switchDelays[appID] = seconds
        UserDefaults.standard.set(switchDelays, forKey: Self.switchDelaysKey)
        refreshKnownApps()
    }

    private func refreshKnownApps() {
        var known: [String: KnownApp] = [:]
        for entry in latest.values {
            known[entry.id] = KnownApp(id: entry.id, name: entry.name, icon: entry.icon, isRunning: true)
        }
        // Hidden or adjusted apps that aren't running: look them up on disk.
        for id in hiddenApps.union(settings.keys).union(switchDelays.keys) where known[id] == nil && !id.hasPrefix("pid:") {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            known[id] = KnownApp(id: id, name: name, icon: NSWorkspace.shared.icon(forFile: url.path), isRunning: false)
        }
        knownApps = known.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    #if DEBUG
    func debugEngineReport() -> [String] {
        guard let driver else { return ["engine: not running"] }
        let stats = driver.stats
        var lines = [String(format: "engine: underruns=%llu resyncs=%llu lag=%.0f target=%u ratio=%.6f",
                            stats.underruns, stats.resyncs, stats.lagFrames, stats.targetFrames, stats.ratio)]
        for peak in driver.takePeaks() {
            lines.append(String(format: "peak pid=%d owner=%d level=%.4f app=%@", peak.pid, peak.ownerPID, peak.level,
                                pidToApp[peak.pid] ?? pidToApp[peak.ownerPID] ?? "?"))
        }
        return lines
    }

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
        if driver != nil {
            taps.values.forEach { $0.invalidate() }
            taps.removeAll()
            return
        }
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
        // With the driver, Volumist stays the default output; picking a device changes where its mix plays.
        if driver != nil, device.direction == .output {
            log.info("Picked \(device.name, privacy: .public) in the menu")
            switchPending = false
            switchToOutput(device)
            return
        }
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
        if direction == .output { pushVolumeToDriver() }
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
        let wasActive = output.devices.contains { $0.id == output.selectedID && $0.isActive }
        // The driver engine can play to headphones macOS hides while they aren't worn, so list
        // them like the Sound menu does.
        output.devices = AudioDevices.all(.output, includeIdle: driver != nil)
        input.devices = AudioDevices.all(.input)
        // The real output went away (unplugged, AirPods taken off): like macOS, go back to the
        // output used before it. Picking idle headphones on purpose isn't "going away".
        guard driver != nil else { return }
        let current = output.devices.first { $0.id == output.selectedID }
        if current == nil || (wasActive && current?.isActive == false), let fallback = fallbackOutput() {
            useRealOutput(fallback)
        }
    }

    /// The most recently used output that's still available, else the built-in one.
    private func fallbackOutput() -> AudioDevice? {
        let available = output.devices.filter {
            $0.isActive && $0.id != output.selectedID && AudioDevices.hasBluetoothAudioLink($0.id) != false
        }
        let history = UserDefaults.standard.stringArray(forKey: Self.outputHistoryKey) ?? []
        for uid in history {
            if let device = available.first(where: { $0.uid == uid }) { return device }
        }
        return available.first { $0.transportType == kAudioDeviceTransportTypeBuiltIn } ?? available.first
    }

    private func defaultDeviceChanged(_ direction: AudioDirection) {
        let id = AudioDevices.defaultDeviceID(direction)
        if direction == .output, driver != nil, !stoppingDriver {
            // Volumist itself is the default: nothing to do. Anything else means the user picked an
            // output in the system Sound menu (or macOS fell back): play the mix there, and
            // driverTick makes Volumist the default again.
            if id != DriverEngine.deviceID, let device = AudioDevices.device(for: id, .output),
               device.uid != AudioDevices.volumistDeviceUID, device.id != output.selectedID {
                log.info("System default output changed to \(device.name, privacy: .public)")
                useRealOutput(device)
            }
            return
        }
        update(direction) { $0.selectedID = id }
        // Only the output has a volume control in the menu.
        guard direction == .output else { return }
        watchOutputVolume(id)
        refreshVolume(.output)
        // Re-route every tap to the new output.
        syncTaps()
    }

    private func watchOutputVolume(_ id: AudioObjectID) {
        outputVolumeListeners = [AudioDevices.volumeAddress(.output), AudioDevices.muteAddress(.output)].map { address in
            PropertyListener(id, address) { [weak self] in
                MainActor.assumeIsolated { self?.refreshVolume(.output) }
            }
        }
    }

    private func refreshVolume(_ direction: AudioDirection) {
        let id = state(direction).selectedID
        update(direction) {
            $0.volumeSettable = AudioDevices.canSetVolume(id, direction)
            $0.volume = Double(AudioDevices.volume(id, direction))
            $0.muted = AudioDevices.isMuted(id, direction)
        }
        if direction == .output { pushVolumeToDriver() }
    }

    // MARK: - Audio driver

    /// Uses the Volumist driver when it's installed (unless Settings chooses audio capture), else taps.
    func configureEngine() {
        let wantDriver = UserDefaults.standard.string(forKey: Preferences.audioEngine) != Preferences.engineCapture
            && DriverEngine.isInstalled && !driverFailed
        if wantDriver, driver == nil { startDriver() }
        if !wantDriver, driver != nil { stopDriver() }
        usingDriver = driver != nil
        refreshApps()
    }

    private func startDriver() {
        guard let real = initialRealOutput(), let engine = DriverEngine() else {
            log.error("Couldn't start the driver engine")
            return
        }
        driver = engine
        usingDriver = true
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
        levelMonitor?.invalidate()
        levelMonitor = nil
        monitoredProcesses = [:]
        UserDefaults.standard.set(true, forKey: Self.engineActiveKey)
        lastDriverVolumeSequence = 0
        lastPushedVolume = -1
        useRealOutput(real)
        refreshDevices()
        driverTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.driverTick() }
        }
        publishRules()
        log.info("Driver engine started, playing to \(real.name, privacy: .public)")
        // If the device never appears (outdated driver, refused handover), fall back to audio
        // capture rather than leave per-app volume dead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak engine] in
            guard let self, let engine, self.driver === engine, !engine.isDeviceVisible else { return }
            self.driverDidNotRespond(reply: engine.driverReply)
        }
    }

    private func driverDidNotRespond(reply: Int32?) {
        switch reply.map(Int.init) {
        case Int(VD_REPLY_NOT_APP):
            driverError = "The audio driver refused this copy of Volumist (its code signature didn't match). Using audio capture."
        case Int(VD_REPLY_UNVERIFIABLE):
            driverError = "The audio driver couldn't verify this copy of Volumist. Using audio capture."
        case .some:
            driverError = "The audio driver couldn't use Volumist's shared memory. Updating the driver should fix this. Using audio capture."
        case nil:
            driverError = "The audio driver didn't connect. It may be out of date: update it below. Using audio capture."
        }
        log.error("Driver didn't respond (reply \(reply.map(String.init) ?? "none", privacy: .public)); falling back to audio capture")
        driverFailed = true
        stopDriver()
        configureEngine()
    }

    /// Gives the default output back to the real device, then removes the Volumist device.
    private func stopDriver() {
        guard let engine = driver else { return }
        stopReclaiming()
        switchPending = false
        nowPlayingClaim.end()
        stoppingDriver = true
        driverTimer?.invalidate()
        driverTimer = nil
        if let real = AudioDevices.device(for: output.selectedID, .output) {
            AudioDevices.setDefault(real)
        }
        engine.shutdown()
        driver = nil
        usingDriver = false
        UserDefaults.standard.set(false, forKey: Self.engineActiveKey)
        stoppingDriver = false
        refreshDevices()
        defaultDeviceChanged(.output)
    }

    /// The user changed the engine in Settings: try the driver again if it's chosen.
    func engineChoiceChanged() {
        driverFailed = false
        driverError = nil
        configureEngine()
    }

    // MARK: - Installing the driver

    func refreshDriverStatus() {
        driverStatus = DriverInstaller.status
    }

    func installDriver() {
        changeDriver { DriverInstaller.install(completion: $0) }
    }

    func uninstallDriver() {
        changeDriver { DriverInstaller.uninstall(completion: $0) }
    }

    private func changeDriver(_ run: (@escaping @MainActor (Result<Void, DriverInstaller.Failure>) -> Void) -> Void) {
        guard !driverBusy else { return }
        driverBusy = true
        driverError = nil
        driverFailed = false
        // Give the default output back to the real device before Core Audio restarts.
        stopDriver()
        awaitingAudioRestart = true
        run { [weak self] result in
            guard let self else { return }
            self.driverBusy = false
            switch result {
            case .success:
                // Core Audio is restarting; audioServiceRestarted() rebuilds everything. In case
                // that notification never arrives, rebuild anyway after a few seconds.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    if self?.awaitingAudioRestart == true { self?.audioServiceRestarted() }
                }
            case .failure(let failure):
                self.awaitingAudioRestart = false
                switch failure {
                case .cancelled: break
                case .notBundled: self.driverError = "This copy of Volumist doesn't include the driver."
                case .failed(let message): self.driverError = message
                }
                self.configureEngine()
            }
            self.refreshDriverStatus()
        }
    }

    /// Core Audio restarted (driver installed or removed, or it crashed): every device and process
    /// object is new, so drop everything that refers to the old ones and set up again.
    private func audioServiceRestarted() {
        awaitingAudioRestart = false
        driverFailed = false
        log.info("Core Audio restarted; rebuilding")
        stopReclaiming()
        if let driver {
            // Not stopDriver(): the old devices are gone, and keeping the "engine active" flag
            // makes the restart go back to the saved real output.
            driverTimer?.invalidate()
            driverTimer = nil
            driver.shutdown()
            self.driver = nil
            usingDriver = false
        }
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
        levelMonitor?.invalidate()
        levelMonitor = nil
        monitoredProcesses = [:]
        processListeners = [:]
        outputVolumeListeners = []
        installSystemListeners()
        refreshDevices()
        defaultDeviceChanged(.output)
        defaultDeviceChanged(.input)
        refreshDriverStatus()
        configureEngine()
    }

    private func initialRealOutput() -> AudioDevice? {
        let candidates = AudioDevices.all(.output)
        let savedUID = UserDefaults.standard.string(forKey: Self.realOutputKey)
        let saved = candidates.first { $0.uid == savedUID }
        // Last run ended without stopping the engine (a crash): macOS will have fallen back to
        // the built-in output, so go back to the device the user was actually using.
        if UserDefaults.standard.bool(forKey: Self.engineActiveKey), let saved { return saved }
        let current = AudioDevices.defaultDeviceID(.output)
        return candidates.first { $0.id == current }
            ?? saved
            ?? candidates.first { $0.transportType == kAudioDeviceTransportTypeBuiltIn }
            ?? candidates.first
    }

    private func reestablishOutput() {
        guard driver != nil, let device = AudioDevices.device(for: output.selectedID, .output) else { return }
        log.info("Re-establishing output to \(device.name, privacy: .public) after wake")
        useRealOutput(device)
    }

    private func useRealOutput(_ device: AudioDevice) {
        guard let driver else { return }
        if !driver.setOutput(device.id) {
            log.error("Couldn't play to \(device.name, privacy: .public)")
        }
        log.info("Playing to \(device.name, privacy: .public)")
        if device.id != output.selectedID { lastRouteChange = Date() }
        UserDefaults.standard.set(device.uid, forKey: Self.realOutputKey)
        var history = UserDefaults.standard.stringArray(forKey: Self.outputHistoryKey) ?? []
        history.removeAll { $0 == device.uid }
        history.insert(device.uid, at: 0)
        UserDefaults.standard.set(Array(history.prefix(10)), forKey: Self.outputHistoryKey)
        output.selectedID = device.id
        watchOutputVolume(device.id)
        refreshVolume(.output)
    }

    #if DEBUG
    private var lastLoggedGlitches: (UInt64, UInt64) = (0, 0)
    #endif

    private func driverTick() {
        guard let driver else { return }
        trackBluetoothLink()
        if takeover == nil, !switchPending { nowPlayingClaim.end() }
        updateReclaiming()
        #if DEBUG
        // Logs underruns and resyncs as they happen, for listening tests.
        let stats = driver.stats
        if (stats.underruns, stats.resyncs) != lastLoggedGlitches {
            lastLoggedGlitches = (stats.underruns, stats.resyncs)
            log.info("Engine: underruns=\(stats.underruns) resyncs=\(stats.resyncs) lag=\(Int(stats.lagFrames)) target=\(stats.targetFrames) ratio=\(stats.ratio)")
        }
        #endif
        // Make the Volumist device the default output once the driver has published it.
        if driver.isDeviceVisible, Date() >= holdDefaultUntil, let volumist = DriverEngine.deviceID,
           AudioDevices.defaultDeviceID(.output) != volumist {
            AudioDevices.setDefaultOutput(volumist)
        }
        // The Volumist device's own volume changed (volume keys, Sound menu): apply it to the
        // real output. Ignore echoes of what we pushed ourselves.
        let sequence = driver.volumeSequence
        guard sequence != lastDriverVolumeSequence else { return }
        lastDriverVolumeSequence = sequence
        let volume = driver.volume, muted = driver.isMuted
        let isEcho = abs(volume - lastPushedVolume) < 0.0005 && muted == lastPushedMute
        let pushedJustNow = Date().timeIntervalSince(lastPushTime) < 0.5
        guard !isEcho, !pushedJustNow, output.selectedID != .unknown else { return }
        AudioDevices.setVolume(output.selectedID, .output, volume)
        AudioDevices.setMuted(output.selectedID, .output, muted)
        refreshVolume(.output)
    }

    /// Plays the mix to `device`. AirPods playing for an iPhone or iPad are taken back the way
    /// the Sound menu does it: by making them the system default until this Mac has them (just
    /// playing to them isn't enough). driverTick makes Volumist the default again as soon as the
    /// link is here. Hidden headphones can't be the default, but playing to them is enough.
    private func switchToOutput(_ device: AudioDevice) {
        guard AudioDevices.hasBluetoothAudioLink(device.id) == false else {
            useRealOutput(device)
            return
        }
        if device.isActive {
            let deadline = Date().addingTimeInterval(Self.takeoverTimeout)
            takeover = (device.id, deadline)
            holdDefaultUntil = deadline
            AudioDevices.setDefault(device)
            useRealOutput(device)
            return
        }
        // Hidden headphones: only a request from a media app wins them back from an iPhone
        // that's playing, so claim Now Playing first and give it a moment to register.
        nowPlayingClaim.begin(title: device.name)
        switchPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.claimLeadSeconds) { [weak self] in
            guard let self, self.switchPending else { return }
            self.switchPending = false
            self.takeover = (device.id, Date().addingTimeInterval(Self.takeoverTimeout))
            self.bounceDefault = (device.id, Date().addingTimeInterval(Self.takeoverTimeout + 2))
            self.useRealOutput(device)
        }
    }

    /// Ends a takeover once the Mac has the headphones, and falls back like macOS does when the
    /// real output's headphones go to another device.
    private func trackBluetoothLink() {
        let id = output.selectedID
        if let pending = takeover, pending.id != id || Date() >= pending.deadline { takeover = nil }
        guard let linked = AudioDevices.hasBluetoothAudioLink(id) else {
            unlinkedSince = nil
            return
        }
        if takeover?.id == id, linked {
            takeover = nil
            holdDefaultUntil = min(holdDefaultUntil, Date().addingTimeInterval(0.3))
        }
        // The headphones came over by Smart Routing's automatic request. Without Volumist, apps'
        // audio restarts on them at this point, and the Mac briefly tells the iPhone it's idle;
        // that's what lets the iPhone take them back automatically when it plays again. Making
        // them the system default for a moment restarts apps' audio the same way.
        if let bounce = bounceDefault {
            if bounce.id != id || Date() >= bounce.until {
                bounceDefault = nil
            } else if linked, takeover == nil, let device = AudioDevices.device(for: id, .output) {
                bounceDefault = nil
                holdDefaultUntil = Date().addingTimeInterval(Self.bounceSeconds)
                AudioDevices.setDefault(device)
            }
        }
        guard !linked, takeover == nil else {
            unlinkedSince = nil
            return
        }
        // A moment's grace: the link can trail the default output when macOS switches to them.
        let since = unlinkedSince ?? Date()
        unlinkedSince = since
        if Date().timeIntervalSince(since) > 1, let fallback = fallbackOutput() {
            let away = AudioDevices.device(for: id, .output, allowHidden: true)
            log.info("\(away?.name ?? "Headphones", privacy: .public) is playing for another device")
            unlinkedSince = nil
            useRealOutput(fallback)
        }
    }

    // MARK: - Taking headphones back

    /// Headphones you're wearing that are with another device (or idle), most recently used first.
    /// Like automatic switching, the Mac takes these when it starts playing.
    private func reclaimableHeadphones() -> [AudioDevice] {
        let history = UserDefaults.standard.stringArray(forKey: Self.outputHistoryKey) ?? []
        return output.devices
            .filter {
                $0.id != output.selectedID && AudioDevices.isWorn($0.id) == true
                    && AudioDevices.hasBluetoothAudioLink($0.id) == false
            }
            .sorted { (history.firstIndex(of: $0.uid) ?? .max) < (history.firstIndex(of: $1.uid) ?? .max) }
    }

    /// Starts or stops the fast check, depending on whether any headphones could be taken back.
    private func updateReclaiming() {
        let wanted = driver != nil && takeover == nil && !switchPending && !reclaimableHeadphones().isEmpty
        if !wanted {
            stopReclaiming()
        } else if reclaimTimer == nil {
            // Whatever is playing right now started before; it doesn't count.
            let start = Date()
            drainDriverPeaks()
            for (key, last) in lastAudible where last >= start { audibleSince[key] = .distantPast }
            reclaimTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reclaimHeadphonesIfPlaying() }
            }
        }
    }

    private func stopReclaiming() {
        reclaimTimer?.invalidate()
        reclaimTimer = nil
    }

    /// Takes worn headphones back as soon as an app starts playing on the Mac, like automatic
    /// switching does. Sound that was already going on before the mix last changed outputs
    /// doesn't count, alert sounds never do, and apps with a switching delay in Settings must
    /// play that long first (so a message ping doesn't take them).
    private func reclaimHeadphonesIfPlaying() {
        guard driver != nil, takeover == nil, !switchPending else { return }
        drainDriverPeaks()
        let now = Date()
        let trigger = lastAudible.first { key, last in
            guard now.timeIntervalSince(last) <= Self.soundGap, let since = audibleSince[key],
                  since > lastRouteChange else { return false }
            return now.timeIntervalSince(since) >= (switchDelays[key] ?? 0)
        }
        guard let trigger, let device = reclaimableHeadphones().first else { return }
        log.info("\(trigger.key, privacy: .public) started playing; switching to \(device.name, privacy: .public)")
        stopReclaiming()
        switchToOutput(device)
    }

    /// Shows the real output's volume on the Volumist device (what the volume keys adjust).
    private func pushVolumeToDriver() {
        guard let driver else { return }
        let volume = Float(output.volume), muted = output.muted
        if volume != lastPushedVolume || muted != lastPushedMute { lastPushTime = Date() }
        lastPushedVolume = volume
        lastPushedMute = muted
        driver.pushVolume(volume, muted: muted)
    }

    /// Publishes every adjusted app's gain to the driver: by bundle ID (covers an app's own
    /// process even before we've seen it), by the app's PID, and by the PIDs of its helper
    /// processes (e.g. Safari's WebKit GPU process).
    private func publishRules() {
        guard let driver else { return }
        var rules: [DriverEngine.Rule] = []
        var seenKeys: Set<String> = []
        func add(_ rule: DriverEngine.Rule) {
            let key = "\(rule.pid)|\(rule.bundleID ?? "")"
            if seenKeys.insert(key).inserted { rules.append(rule) }
        }
        let running = NSWorkspace.shared.runningApplications
        for (key, setting) in settings {
            let gain = setting.gain
            if key.hasPrefix("pid:") {
                if let pid = pid_t(key.dropFirst(4)) { add(.init(pid: pid, gain: gain)) }
            } else {
                add(.init(bundleID: key, gain: gain))
                for app in running where app.bundleIdentifier == key { add(.init(pid: app.processIdentifier, gain: gain)) }
            }
            for pid in latest[key]?.processPIDs ?? [] { add(.init(pid: pid, gain: gain)) }
        }
        driver.setRules(rules)
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
