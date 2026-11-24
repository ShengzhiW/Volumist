import CoreAudio
import AudioToolbox
import Foundation

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32

    /// SF Symbol that mirrors the icons the system Sound menu uses.
    var symbolName: String {
        let lower = name.lowercased()
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            if lower.contains("headphone") { return "headphones" }
            return lower.contains("macbook") ? "laptopcomputer" : "speaker.wave.2.fill"
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
        default:
            return "speaker.wave.2.fill"
        }
    }
}

enum OutputDevices {
    /// UID prefix of the private aggregate devices Volumist creates, so they never show up in the list.
    static let privateUIDPrefix = "app.volumist.aggregate."

    static func all() -> [OutputDevice] {
        let ids = CA.getArray(.system, CA.address(kAudioHardwarePropertyDevices), zero: AudioObjectID.unknown)
        let devices = ids.compactMap(device(for:)).filter { !$0.uid.hasPrefix(privateUIDPrefix) }
        // Like the system menu: built-in output first, everything else in Core Audio's order.
        return devices.filter { $0.transportType == kAudioDeviceTransportTypeBuiltIn }
            + devices.filter { $0.transportType != kAudioDeviceTransportTypeBuiltIn }
    }

    static func device(for id: AudioObjectID) -> OutputDevice? {
        let streams = CA.getArray(id, CA.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput), zero: AudioObjectID.unknown)
        guard !streams.isEmpty else { return nil }
        if let hidden = CA.get(id, CA.address(kAudioDevicePropertyIsHidden), initial: UInt32(0)), hidden != 0 { return nil }
        if let canBeDefault = CA.get(id, CA.address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput), initial: UInt32(1)),
           canBeDefault == 0 { return nil }
        guard let uid = CA.getString(id, CA.address(kAudioDevicePropertyDeviceUID)) else { return nil }
        let name = CA.getString(id, CA.address(kAudioObjectPropertyName))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown Device"
        let transport = CA.get(id, CA.address(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0
        return OutputDevice(id: id, uid: uid, name: name, transportType: transport)
    }

    static var defaultOutputID: AudioObjectID {
        CA.get(.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioObjectID.unknown) ?? .unknown
    }

    static func setDefaultOutput(_ id: AudioObjectID) {
        CA.set(.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    // MARK: Volume

    static let volumeAddress = CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    static let muteAddress = CA.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)

    static func canSetVolume(_ id: AudioObjectID) -> Bool {
        CA.isSettable(id, volumeAddress)
    }

    static func volume(_ id: AudioObjectID) -> Float {
        CA.get(id, volumeAddress, initial: Float32(0)) ?? 0
    }

    static func setVolume(_ id: AudioObjectID, _ value: Float) {
        CA.set(id, volumeAddress, Float32(min(max(value, 0), 1)))
        if value > 0, isMuted(id) { setMuted(id, false) }
    }

    static func isMuted(_ id: AudioObjectID) -> Bool {
        (CA.get(id, muteAddress, initial: UInt32(0)) ?? 0) != 0
    }

    static func setMuted(_ id: AudioObjectID, _ muted: Bool) {
        guard CA.isSettable(id, muteAddress) else { return }
        CA.set(id, muteAddress, UInt32(muted ? 1 : 0))
    }

    /// Zero-based indices of the device's preferred stereo pair (usually 0 and 1).
    static func stereoChannels(_ id: AudioObjectID) -> (left: Int, right: Int) {
        let pair = CA.getArray(id, CA.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput), zero: UInt32(0))
        guard pair.count == 2, pair[0] > 0, pair[1] > 0 else { return (0, 1) }
        return (Int(pair[0]) - 1, Int(pair[1]) - 1)
    }
}
