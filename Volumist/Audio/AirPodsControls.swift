import CoreAudio
import Foundation
import IOBluetooth

/// Listening mode and battery for AirPods and Beats, like the system Sound menu.
///
/// None of this is public API. The listening mode is an undocumented property of the
/// headphones' Core Audio device (Apple's Bluetooth audio plug-in passes writes on to the
/// headphones); battery comes from undocumented IOBluetooth accessors. Everything is read
/// defensively: if a property is missing, that control is simply not shown.
///
/// Not here: Spatial Audio (its Core Audio properties only report the state; changing it takes
/// AVFoundation calls reserved for Apple's apps) and Conversation Awareness (not exposed).
///
/// Only the properties used here are touched. Reading every private property of an AirPods
/// device at once made macOS drop and re-add it, so don't widen this without testing.
enum AirPodsControls {
    enum ListeningMode: UInt32, CaseIterable, Identifiable {
        case off = 1, noiseCancellation = 2, transparency = 3, adaptive = 4

        var id: Self { self }

        var title: String {
            switch self {
            case .off: return "Off"
            case .noiseCancellation: return "Noise Cancellation"
            case .transparency: return "Transparency"
            case .adaptive: return "Adaptive"
            }
        }

        /// The symbols the system Sound menu uses. All but Off are private system symbols
        /// (see `MenuSymbol`).
        var symbol: String {
            switch self {
            case .off: return "person.crop.circle"
            case .noiseCancellation: return "person.closed.fill"
            case .transparency: return "person.open.fill"
            case .adaptive: return "person.and.sparkles.fill"
            }
        }

        /// The order the system menu lists them in.
        static let menuOrder: [ListeningMode] = [.off, .transparency, .adaptive, .noiseCancellation]

        /// Bit in the device's list of offered modes.
        fileprivate var offeredBit: UInt32 {
            switch self {
            case .noiseCancellation: return 1 << 0
            case .transparency: return 1 << 1
            case .adaptive: return 1 << 2
            case .off: return 1 << 3
            }
        }
    }

    struct Battery: Equatable {
        var left: Int?
        var right: Int?
        var chargingCase: Int?
        /// Headphones with one battery (AirPods Max, most Beats).
        var single: Int?

        var isEmpty: Bool { left == nil && right == nil && chargingCase == nil && single == nil }
    }

    struct State: Equatable {
        var listeningMode: ListeningMode?
        var offeredModes: [ListeningMode]
        var battery: Battery?
    }

    /// The current state of `device`, or nil if it isn't headphones with these controls.
    static func state(of device: AudioDevice) -> State? {
        guard device.direction == .output,
              device.transportType == kAudioDeviceTransportTypeBluetooth
                || device.transportType == kAudioDeviceTransportTypeBluetoothLE,
              let modeValue = read(device.id, Selector.listeningMode) else { return nil }
        let offered = read(device.id, Selector.offeredModes) ?? 0
        var modes = ListeningMode.menuOrder.filter { offered & $0.offeredBit != 0 }
        let current = ListeningMode(rawValue: modeValue)
        // Always offer the current mode, even if the list of offered modes doesn't say so.
        if let current, !modes.contains(current) {
            modes = ListeningMode.menuOrder.filter { modes.contains($0) || $0 == current }
        }
        return State(listeningMode: current, offeredModes: modes, battery: battery(device.uid))
    }

    static func setListeningMode(_ mode: ListeningMode, on device: AudioDevice) {
        write(device.id, Selector.listeningMode, mode.rawValue)
    }

    // MARK: - Private

    private enum Selector {
        static let listeningMode: AudioObjectPropertySelector = 0x6C73_746D   // 'lstm'
        static let offeredModes: AudioObjectPropertySelector = 0x6C73_6D73    // 'lsms'
    }

    private static func read(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        let address = CA.address(selector)
        guard CA.has(id, address) else { return nil }
        return CA.get(id, address, initial: UInt32(0))
    }

    private static func write(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: UInt32) {
        _ = CA.set(id, CA.address(selector), value)
    }

    /// Battery levels from Bluetooth. The device UID of Bluetooth audio is its address
    /// ("D4-12-6E-0E-98-1C:output").
    private static func battery(_ uid: String) -> Battery? {
        guard let address = uid.split(separator: ":").first.map({ $0.replacingOccurrences(of: "-", with: ":") }),
              let device = IOBluetoothDevice(addressString: address) else { return nil }
        func percent(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)),
                  let value = device.value(forKey: key) as? Int, value > 0 else { return nil }
            return value
        }
        let battery = Battery(left: percent("batteryPercentLeft"), right: percent("batteryPercentRight"),
                              chargingCase: percent("batteryPercentCase"), single: percent("batteryPercentSingle"))
        return battery.isEmpty ? nil : battery
    }
}
