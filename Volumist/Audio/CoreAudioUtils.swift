import CoreAudio
import AudioToolbox
import Foundation

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)
}

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String
    var description: String { "\(context) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, context: context()) }
}

/// Thin, typed wrappers around the AudioObject property API.
enum CA {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        return AudioObjectHasProperty(id, &a)
    }

    static func isSettable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &a),
              AudioObjectIsPropertySettable(id, &a, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func get<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) -> T? {
        var a = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func getArray<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, zero: T) -> [T] {
        var a = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        let status = items.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(items.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func getString(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var a = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    @discardableResult
    static func set<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = address
        var v = value
        return withUnsafeMutablePointer(to: &v) {
            AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }
}

/// Registers a Core Audio property listener for its lifetime.
final class PropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let registered: Bool

    init(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, queue: DispatchQueue = .main, handler: @escaping () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var a = address
        self.objectID = objectID
        self.address = address
        self.block = block
        self.queue = queue
        registered = AudioObjectAddPropertyListenerBlock(objectID, &a, queue, block) == noErr
    }

    private let queue: DispatchQueue

    deinit {
        if registered {
            AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
        }
    }
}
