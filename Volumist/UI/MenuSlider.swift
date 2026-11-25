import SwiftUI

/// Volume slider for the menu. Uses the system slider, which on macOS 26 and later is the
/// Liquid Glass slider (a glass knob that becomes a lens while dragging).
struct MenuSlider: View {
    @Binding var value: Double
    var isEnabled = true
    var isDimmed = false
    var controlSize: ControlSize = .regular
    /// Snap to multiples of this (e.g. 0.1 for 10%); 0 for continuous.
    var step: Double = 0
    /// Called with true when a drag (or click) starts and false when it ends.
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Slider(value: Binding(get: { value }, set: { value = snapped($0) }), in: 0...1, onEditingChanged: onEditingChanged)
            .labelsHidden()
            .controlSize(controlSize)
            .tint(isDimmed ? Color.secondary : Color.accentColor)
            .disabled(!isEnabled)
            .accessibilityLabel("Volume")
    }

    private func snapped(_ raw: Double) -> Double {
        guard step > 0 else { return raw }
        return min(max((raw / step).rounded() * step, 0), 1)
    }
}
