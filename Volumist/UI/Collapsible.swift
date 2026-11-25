import SwiftUI

/// Content that opens and closes by growing and shrinking its height, with the menu window
/// following smoothly.
///
/// A SwiftUI animation can't do this: the menu bar window is resized once, to the final size,
/// so it jumps while the rows inside animate. Here the shown height is changed on every frame
/// with animations off, so the window's real size changes along with it.
struct Collapsible<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder var content: Content

    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat?
    @State private var driver = HeightDriver()

    var body: some View {
        let height = shownHeight ?? (isExpanded ? fullHeight : 0)
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: HeightKey.self, value: geometry.size.height)
            })
            .opacity(fullHeight > 0 ? min(1, height / fullHeight * 1.4) : 1)
            .frame(height: height, alignment: .top)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
            .onPreferenceChange(HeightKey.self) { newHeight in
                fullHeight = newHeight
                // Content changed size while settled (a device appeared): follow it directly.
                if !driver.isRunning { shownHeight = isExpanded ? newHeight : 0 }
            }
            .onChange(of: isExpanded) { _, expanded in
                driver.run(from: height, to: expanded ? fullHeight : 0) { value in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { shownHeight = value }
                }
            }
            .onDisappear { driver.stop() }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Steps a value from one height to another with an ease-in-out curve, once per frame.
@MainActor
private final class HeightDriver {
    private var timer: Timer?
    var isRunning: Bool { timer != nil }

    static let duration: TimeInterval = 0.22

    func run(from start: CGFloat, to end: CGFloat, update: @escaping (CGFloat) -> Void) {
        stop()
        guard start != end else { update(end); return }
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let progress = min(1, Date().timeIntervalSince(began) / Self.duration)
                let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
                update(start + (end - start) * eased)
                if progress >= 1 {
                    timer.invalidate()
                    self?.timer = nil
                }
            }
        }
        // Keep stepping while the mouse is down or a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
