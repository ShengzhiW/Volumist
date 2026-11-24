import SwiftUI

/// A slider styled like the ones in the macOS Control Center / Sound menu:
/// a thin rounded track with an accent fill and a white capsule knob.
struct MenuSlider: View {
    @Binding var value: Double
    var isEnabled = true
    var isDimmed = false
    var trackHeight: CGFloat = 6
    var knobSize = CGSize(width: 24, height: 16)

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let travel = max(width - knobSize.width, 1)
            let knobX = travel * CGFloat(min(max(value, 0), 1))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(fillColor)
                    .frame(width: knobX + knobSize.width / 2, height: trackHeight)

                Capsule()
                    .fill(Color.white)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                    .shadow(color: .black.opacity(isDragging ? 0.3 : 0.22), radius: isDragging ? 2.5 : 1.5, y: 0.5)
                    .frame(width: knobSize.width, height: knobSize.height)
                    .scaleEffect(isDragging ? 1.06 : 1)
                    .offset(x: knobX)
                    .animation(.easeOut(duration: 0.12), value: isDragging)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        isDragging = true
                        value = Double(min(max((gesture.location.x - knobSize.width / 2) / travel, 0), 1))
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: knobSize.height + 2)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.0625, 1)
            case .decrement: value = max(value - 0.0625, 0)
            @unknown default: break
            }
        }
    }

    private var fillColor: Color {
        isDimmed ? Color.primary.opacity(0.3) : Color.accentColor
    }
}
