import SwiftUI

@main
struct VolumistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appDelegate.model)
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

    override init() {
        #if DEBUG
        SelfTest.runIfRequested()
        #endif
        model = MixerModel()
        super.init()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
