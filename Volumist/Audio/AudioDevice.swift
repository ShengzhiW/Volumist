import CoreAudio
import AudioToolbox
import Foundation

enum AudioDirection {
    case output
    case input

    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
    }

    var defaultDeviceSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32
    let direction: AudioDirection
    /// False for Bluetooth headphones that are connected but idle: macOS hides AirPods while
    /// they're out of your ears or off your head, yet still lists them in the Sound menu.
    var isActive = true

    /// SF Symbol that mirrors the icons the system Sound menu uses.
    var symbolName: String {
        let lower = name.lowercased()
        let generic = direction == .output ? "speaker.wave.2.fill" : "mic.fill"
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            if lower.contains("headphone") { return "headphones" }
            return lower.contains("macbook") ? "laptopcomputer" : generic
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            return "display"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            if lower.contains("beats") { return "beats.headphones" }
            return "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            if lower.contains("homepod") { return "homepod.fill" }
            if lower.contains("theater") || lower.contains("apple tv") { return "appletv.fill" }
            return "airplayaudio"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "iphone"
        default:
            return generic
        }
    }
}

enum AudioDevices {
    /// UID prefix of the private aggregate devices Volumist creates, so they never show up in the list.
    static let privateUIDPrefix = "app.volumist.aggregate."
    /// The Volumist driver's device: the default output while the driver engine runs, so it's
    /// left out of device lists (the menu shows the real device its mix plays to instead).
    static let volumistDeviceUID = "app.volumist.device"

    /// The devices in `direction`. `includeIdle` adds connected Bluetooth headphones that macOS
    /// hides while they aren't being worn (only the driver engine can play to those).
    static func all(_ direction: AudioDirection, includeIdle: Bool = false) -> [AudioDevice] {
        let ids = CA.getArray(.system, CA.address(kAudioHardwarePropertyDevices), zero: AudioObjectID.unknown)
        var devices = ids.compactMap { device(for: $0, direction) }
            .filter { !$0.uid.hasPrefix(privateUIDPrefix) && $0.uid != volumistDeviceUID }
        if includeIdle {
            // Hidden devices aren't in the device list, but the system object still owns them.
            let owned = CA.getArray(.system, CA.address(kAudioObjectPropertyOwnedObjects), zero: AudioObjectID.unknown)
            for id in owned where !ids.contains(id) {
                guard var idle = device(for: id, direction, allowHidden: true),
                      idle.transportType == kAudioDeviceTransportTypeBluetooth
                          || idle.transportType == kAudioDeviceTransportTypeBluetoothLE,
                      CA.get(id, CA.address(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0)) == 1,
                      !devices.contains(where: { $0.uid == idle.uid }) else { continue }
                idle.isActive = false
                devices.append(idle)
            }
        }
        // Like the system menu: built-in devices first, everything else in Core Audio's order.
        return devices.filter { $0.transportType == kAudioDeviceTransportTypeBuiltIn }
            + devices.filter { $0.transportType != kAudioDeviceTransportTypeBuiltIn }
    }

    static func device(for id: AudioObjectID, _ direction: AudioDirection, allowHidden: Bool = false) -> AudioDevice? {
        let streams = CA.getArray(id, CA.address(kAudioDevicePropertyStreams, scope: direction.scope), zero: AudioObjectID.unknown)
        guard !streams.isEmpty else { return nil }
        if !allowHidden, let hidden = CA.get(id, CA.address(kAudioDevicePropertyIsHidden), initial: UInt32(0)), hidden != 0 { return nil }
        if let canBeDefault = CA.get(id, CA.address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: direction.scope), initial: UInt32(1)),
           canBeDefault == 0 { return nil }
        guard let uid = CA.getString(id, CA.address(kAudioDevicePropertyDeviceUID)) else { return nil }
        let name = CA.getString(id, CA.address(kAudioObjectPropertyName))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown Device"
        let transport = CA.get(id, CA.address(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0
        return AudioDevice(id: id, uid: uid, name: name, transportType: transport, direction: direction)
    }

    /// Whether this Mac has the audio link to a Bluetooth device right now. AirPods stay listed
    /// while they play for an iPhone or iPad (automatic switching), and only this flag changes.
    /// It's an undocumented property of Apple's Bluetooth audio plug-in, so it's nil if missing.
    static func hasBluetoothAudioLink(_ id: AudioObjectID) -> Bool? {
        CA.get(id, CA.address(bluetoothAudioLinkSelector), initial: UInt32(0)).map { $0 != 0 }
    }

    private static let bluetoothAudioLinkSelector: AudioObjectPropertySelector = 0x626F_6163 // 'boac'

    /// Whether AirPods are in your ears (or on your head): 1 means in, 2 out, per earbud. Also
    /// undocumented; nil for headphones without ear detection.
    static func isWorn(_ id: AudioObjectID) -> Bool? {
        let buds = [inEarPrimarySelector, inEarSecondarySelector].compactMap {
            CA.get(id, CA.address($0), initial: UInt32(0))
        }
        return buds.isEmpty ? nil : buds.contains(1)
    }

    private static let inEarPrimarySelector: AudioObjectPropertySelector = 0x6965_7370 // 'iesp'
    private static let inEarSecondarySelector: AudioObjectPropertySelector = 0x6965_7373 // 'iess'

    static func defaultDeviceID(_ direction: AudioDirection) -> AudioObjectID {
        CA.get(.system, CA.address(direction.defaultDeviceSelector), initial: AudioObjectID.unknown) ?? .unknown
    }

    static func setDefault(_ device: AudioDevice) {
        CA.set(.system, CA.address(device.direction.defaultDeviceSelector), device.id)
    }

    static func setDefaultOutput(_ id: AudioObjectID) {
        CA.set(.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    // MARK: Volume

    static func volumeAddress(_ direction: AudioDirection) -> AudioObjectPropertyAddress {
        CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: direction.scope)
    }

    static func muteAddress(_ direction: AudioDirection) -> AudioObjectPropertyAddress {
        CA.address(kAudioDevicePropertyMute, scope: direction.scope)
    }

    static func canSetVolume(_ id: AudioObjectID, _ direction: AudioDirection) -> Bool {
        CA.isSettable(id, volumeAddress(direction))
    }

    static func volume(_ id: AudioObjectID, _ direction: AudioDirection) -> Float {
        CA.get(id, volumeAddress(direction), initial: Float32(0)) ?? 0
    }

    static func setVolume(_ id: AudioObjectID, _ direction: AudioDirection, _ value: Float) {
        CA.set(id, volumeAddress(direction), Float32(min(max(value, 0), 1)))
        if value > 0, isMuted(id, direction) { setMuted(id, direction, false) }
    }

    static func isMuted(_ id: AudioObjectID, _ direction: AudioDirection) -> Bool {
        (CA.get(id, muteAddress(direction), initial: UInt32(0)) ?? 0) != 0
    }

    static func setMuted(_ id: AudioObjectID, _ direction: AudioDirection, _ muted: Bool) {
        guard CA.isSettable(id, muteAddress(direction)) else { return }
        CA.set(id, muteAddress(direction), UInt32(muted ? 1 : 0))
    }

    /// Zero-based indices of the output's preferred stereo pair (usually 0 and 1).
    static func stereoChannels(_ id: AudioObjectID) -> (left: Int, right: Int) {
        let pair = CA.getArray(id, CA.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput), zero: UInt32(0))
        guard pair.count == 2, pair[0] > 0, pair[1] > 0 else { return (0, 1) }
        return (Int(pair[0]) - 1, Int(pair[1]) - 1)
    }
}
