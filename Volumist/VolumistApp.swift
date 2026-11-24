import SwiftUI

@main
struct VolumistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appDelegate.model)
                .environment(\.openVolumistSettings, appDelegate.showSettings)
        } label: {
            Image(systemName: "slider.vertical.3")
                .accessibilityLabel("Volumist")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: MixerModel
    private lazy var settingsWindow = SettingsWindowController(model: model)

    func showSettings() {
        settingsWindow.show()
    }

    override init() {
        // Only one copy may run: a second one would replace the first's shared memory with the
        // driver and break its audio routing. Checked before anything touches audio.
        let me = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .contains(where: { $0.processIdentifier != me && !$0.isTerminated }) {
            exit(0)
        }
        #if DEBUG
        SelfTest.runIfRequested()
        #endif
        model = MixerModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        SelfTest.runAfterLaunchIfRequested(model: model)
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
