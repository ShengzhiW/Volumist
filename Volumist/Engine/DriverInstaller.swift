import Foundation

/// Installs, updates and removes the Volumist audio driver from the copy bundled in the app.
///
/// Writing to /Library/Audio/Plug-Ins/HAL needs administrator rights, so the work runs through
/// AppleScript's `with administrator privileges`, which shows macOS's standard password prompt.
/// Afterwards Core Audio is restarted so it loads (or forgets) the driver; sound stops for a moment.
enum DriverInstaller {
    enum Status: Equatable {
        case notInstalled
        case installed(version: String)
        /// The app carries a different build than the one installed.
        case updateAvailable(installed: String, bundled: String)
        case notBundled
    }

    enum Failure: Error {
        case cancelled
        case notBundled
        case failed(String)
    }

    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/VolumistDriver.driver")
    static var bundledURL: URL? { Bundle.main.url(forResource: "VolumistDriver", withExtension: "driver") }

    static var status: Status {
        guard let bundled = bundledURL else {
            return FileManager.default.fileExists(atPath: installedURL.path) ? .installed(version: version(of: installedURL)) : .notBundled
        }
        guard FileManager.default.fileExists(atPath: installedURL.path) else { return .notInstalled }
        let installedVersion = version(of: installedURL), bundledVersion = version(of: bundled)
        if installedVersion != bundledVersion || executable(of: installedURL) != executable(of: bundled) {
            return .updateAvailable(installed: installedVersion, bundled: bundledVersion)
        }
        return .installed(version: installedVersion)
    }

    /// Copies the bundled driver into place (replacing any older one, and the old spike driver).
    static func install(completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        guard let bundled = bundledURL else {
            Task { @MainActor in completion(.failure(.notBundled)) }
            return
        }
        let destination = installedURL.path
        let command = [
            "/bin/rm -rf \(shellQuoted(destination)) /Library/Audio/Plug-Ins/HAL/VolumistSpike.driver",
            "/bin/mkdir -p /Library/Audio/Plug-Ins/HAL",
            "/usr/bin/ditto \(shellQuoted(bundled.path)) \(shellQuoted(destination))",
            "/usr/sbin/chown -R root:wheel \(shellQuoted(destination))",
            "(/usr/sbin/pkgutil --forget app.volumist.driver >/dev/null 2>&1 || true)",
            "(/usr/bin/killall coreaudiod || true)",
        ].joined(separator: " && ")
        runAsAdministrator(command, prompt: "Volumist wants to install its audio driver.", completion: completion)
    }

    static func uninstall(completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        let command = [
            "/bin/rm -rf \(shellQuoted(installedURL.path)) /Library/Audio/Plug-Ins/HAL/VolumistSpike.driver",
            "(/usr/sbin/pkgutil --forget app.volumist.driver >/dev/null 2>&1 || true)",
            "(/usr/bin/killall coreaudiod || true)",
        ].joined(separator: " && ")
        runAsAdministrator(command, prompt: "Volumist wants to remove its audio driver.", completion: completion)
    }

    // MARK: - Helpers

    private static func version(of bundle: URL) -> String {
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static func executable(of bundle: URL) -> Data? {
        try? Data(contentsOf: bundle.appendingPathComponent("Contents/MacOS/VolumistDriver"))
    }

    /// Single-quotes a path for /bin/sh.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes text for an AppleScript string literal.
    private static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runAsAdministrator(_ command: String, prompt: String, completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        let source = "do shell script \(appleScriptString(command)) with administrator privileges with prompt \(appleScriptString(prompt))"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let result: Result<Void, Failure>
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                result = code == -128 ? .failure(.cancelled) : .failure(.failed(message))
            } else {
                result = .success(())
            }
            Task { @MainActor in completion(result) }
        }
    }
}
