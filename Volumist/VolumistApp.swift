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
