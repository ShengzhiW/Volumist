import AppKit
import Foundation

/// Status of the "Audio Capture" privacy permission that process taps require.
///
/// There's no public API to query it, so this uses the TCC framework when present
/// and falls back to `.unknown` (which simply lets Core Audio prompt on first use).
enum AudioCapturePermission: Equatable {
    case unknown
    case authorized
    case denied

    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var current: AudioCapturePermission {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(symbol, to: PreflightFn.self)
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping (AudioCapturePermission) -> Void) {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else {
            completion(.unknown)
            return
        }
        let request = unsafeBitCast(symbol, to: RequestFn.self)
        request(service, nil) { granted in
            DispatchQueue.main.async { completion(granted ? .authorized : .denied) }
        }
    }

    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
