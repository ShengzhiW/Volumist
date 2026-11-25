import AppKit
import SwiftUI

/// The Settings window: native toolbar tabs (Apps, Devices, Switching, General, About), each a SwiftUI view.
///
/// Volumist normally has no Dock icon. While Settings is open it becomes a regular app so
/// the window can come forward, appear in ⌘-Tab, and take keyboard focus.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: MixerModel
    private var window: NSWindow?

    private static let windowIdentifier = NSUserInterfaceItemIdentifier("VolumistSettings")

    static func isSettingsWindow(_ object: Any?) -> Bool {
        (object as? NSWindow)?.identifier == windowIdentifier
    }

    init(model: MixerModel) {
        self.model = model
    }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab("Apps", symbol: "square.grid.2x2", AppsSettingsView()))
        tabs.addTabViewItem(tab("Devices", symbol: "hifispeaker.2", DevicesSettingsView()))
        tabs.addTabViewItem(tab("Switching", symbol: "arrow.triangle.swap", SwitchingSettingsView()))
        tabs.addTabViewItem(tab("General", symbol: "gearshape", GeneralSettingsView()))
        tabs.addTabViewItem(tab("About", symbol: "info.circle", AboutSettingsView()))
        tabs.selectedTabViewItemIndex = 3

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.identifier = Self.windowIdentifier
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("VolumistSettings")
        return window
    }

    #if DEBUG
    /// Renders each tab of a fresh, offscreen Settings window (toolbar included) to PNGs.
    func snapshotTabs(to directory: URL) {
        let window = makeWindow()
        window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        window.orderFrontRegardless()
        guard let tabs = window.contentViewController as? NSTabViewController,
              let frameView = window.contentView?.superview else { return }
        for index in tabs.tabViewItems.indices {
            tabs.selectedTabViewItemIndex = index
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let name = tabs.tabViewItems[index].label.lowercased()
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("window-\(name).png"))
        }
        window.orderOut(nil)
    }
    #endif

    private func tab(_ title: String, symbol: String, _ view: some View) -> NSTabViewItem {
        let host = NSHostingController(rootView: view.environmentObject(model))
        host.sizingOptions = .preferredContentSize
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

// MARK: - Opening from SwiftUI

private struct OpenVolumistSettingsKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    /// Opens the Settings window.
    var openVolumistSettings: @MainActor () -> Void {
        get { self[OpenVolumistSettingsKey.self] }
        set { self[OpenVolumistSettingsKey.self] = newValue }
    }
}
