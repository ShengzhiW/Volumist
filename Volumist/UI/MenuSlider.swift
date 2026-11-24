import SwiftUI

/// Volume slider for the menu. Uses the system slider, which on macOS 26 and later is the
/// Liquid Glass slider (a glass knob that becomes a lens while dragging).
struct MenuSlider: View {
    @Binding var value: Double
    var isEnabled = true
    var isDimmed = false
    var controlSize: ControlSize = .regular

    var body: some View {
        Slider(value: $value, in: 0...1)
            .labelsHidden()
            .controlSize(controlSize)
            .tint(isDimmed ? Color.secondary : Color.accentColor)
            .disabled(!isEnabled)
            .accessibilityLabel("Volume")
    }
}
