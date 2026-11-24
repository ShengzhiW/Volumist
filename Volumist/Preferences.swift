import Foundation

/// UserDefaults keys for settings that only affect the menu's presentation.
/// Read them with `@AppStorage(Preferences.…)` so the menu updates live.
enum Preferences {
    static let mainVolumeStep = "mainVolumeStep"
    static let appVolumeStep = "appVolumeStep"
    static let showOutputSection = "showOutputSection"
    static let showInputSection = "showInputSection"
    static let outputExpanded = "outputDevicesExpanded"
    static let inputExpanded = "inputDevicesExpanded"

    /// Slider snapping choices: 0 means continuous.
    static let volumeSteps: [(value: Double, label: String)] = [
        (0, "Continuous"),
        (0.05, "5% steps"),
        (0.10, "10% steps"),
        (0.20, "20% steps"),
    ]
}
