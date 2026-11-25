import SwiftUI

/// The menu bar panel, laid out like the system Sound menu.
struct MenuContentView: View {
    @EnvironmentObject private var model: MixerModel
    @Environment(\.openVolumistSettings) private var openSettings
    @AppStorage(Preferences.showOutputSection) private var showOutputSection = true
    @AppStorage(Preferences.showInputSection) private var showInputSection = true
    /// Whether each device list shows every device or just the selected one. Remembered
    /// across menu openings and launches.
    @AppStorage(Preferences.outputExpanded) private var outputExpanded = false
    @AppStorage(Preferences.inputExpanded) private var inputExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sound")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                if model.output.volumeSettable {
                    VolumeLabel(volume: model.output.volume, isMuted: model.output.muted)
                }
            }
                .padding(.horizontal, MenuMetrics.inset)
                .padding(.top, 11)
                .padding(.bottom, 9)

            OutputVolumeRow()

            MenuSeparator()
            SectionHeader("Applications")

            if model.permission == .denied {
                // Per-app volume needs the permission; show only how to grant it.
                PermissionRow()
            } else if model.apps.isEmpty {
                Text("No apps are playing audio")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, MenuMetrics.inset)
                    .padding(.vertical, 6)
            } else {
                AppList(apps: model.apps)
            }

            if showOutputSection {
                MenuSeparator()
                DeviceSection(title: "Output", state: model.output, isExpanded: $outputExpanded)
            }

            if showInputSection {
                MenuSeparator()
                DeviceSection(title: "Input", state: model.input, isExpanded: $inputExpanded)
            }

            MenuSeparator()
            MenuActionRow(title: "Sound Settings…") { model.openSoundSettings() }
            MenuActionRow(title: "Volumist Settings…") { openSettings() }
            MenuActionRow(title: "Quit Volumist") { NSApp.terminate(nil) }
        }
        .padding(.bottom, 6)
        .frame(width: MenuMetrics.width)
        .onAppear(perform: menuOpened)
        // Only the menu's own window counts, not the Settings window.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if !SettingsWindowController.isSettingsWindow(note.object) { menuOpened() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if !SettingsWindowController.isSettingsWindow(note.object) { model.menuDidClose() }
        }
    }

    private func menuOpened() {
        model.menuWillOpen()
    }
}

enum MenuMetrics {
    static let width: CGFloat = 310
    static let inset: CGFloat = 14
    static let iconSize: CGFloat = 26
}

// MARK: - Output volume

private struct OutputVolumeRow: View {
    @EnvironmentObject private var model: MixerModel
    @AppStorage(Preferences.mainVolumeStep) private var step = 0.0

    var body: some View {
        let state = model.output
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13))
                .frame(width: 16)
            MenuSlider(
                value: Binding(get: { state.muted ? 0 : state.volume }, set: { model.setVolume($0, .output) }),
                isEnabled: state.volumeSettable,
                step: step
            )
            MuteButton(isMuted: state.muted, label: "Output") {
                model.toggleMute(.output)
            }
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.horizontal, MenuMetrics.inset)
        .padding(.bottom, 8)
        .accessibilityLabel("Output volume")
    }
}

// MARK: - Applications

private struct AppList: View {
    let apps: [AppAudio]
    private let maxVisible = 7
    private let rowHeight: CGFloat = 46

    var body: some View {
        if apps.count > maxVisible {
            ScrollView(.vertical) { rows }
                .scrollIndicators(.automatic)
                .frame(height: rowHeight * CGFloat(maxVisible) + rowHeight / 2)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(apps) { app in
                AppRow(app: app).frame(height: rowHeight)
            }
        }
    }
}

private struct AppRow: View {
    @EnvironmentObject private var model: MixerModel
    let app: AppAudio
    @AppStorage(Preferences.appVolumeStep) private var step = 0.0
    @State private var iconHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button { model.open(app) } label: {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .opacity(app.isMuted ? 0.45 : 1)
                    .brightness(iconHovered ? -0.06 : 0)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { iconHovered = $0 }
            .help("Open \(app.name)")
            .accessibilityLabel("Open \(app.name)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if app.isAudible {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                    }
                    if let title = app.nowPlaying {
                        // Fills the space up to the percentage, fading out if it's longer.
                        MarqueeText(title, scrolls: app.isAudible, session: model.menuSession)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                            .padding(.trailing, 6)
                            .help(title)
                    } else {
                        Spacer(minLength: 6)
                    }
                    VolumeLabel(volume: app.volume, isMuted: app.isMuted)
                }
                HStack(spacing: 8) {
                    MenuSlider(
                        value: Binding(get: { app.isMuted ? 0 : app.volume }, set: { model.setVolume($0, for: app.id) }),
                        isDimmed: app.isMuted,
                        controlSize: .small,
                        step: step
                    )
                    MuteButton(isMuted: app.isMuted, size: 20, label: app.name) {
                        model.toggleMute(for: app.id)
                    }
                }
            }
        }
        .padding(.horizontal, MenuMetrics.inset)
    }
}

private struct PermissionRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                CircleIcon(symbol: "waveform", tint: .orange, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow System Audio Recording")
                        .font(.system(size: 13, weight: .medium))
                    Text("Volumist needs this permission to change each app's volume. Turn on Volumist under System Audio Recording Only in Privacy & Security.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Open Privacy & Security…", action: AudioCapturePermission.openPrivacySettings)
                .controlSize(.small)
                .padding(.leading, MenuMetrics.iconSize + 10)
        }
        .padding(.horizontal, MenuMetrics.inset)
        .padding(.vertical, 4)
    }
}

// MARK: - Devices

/// A device list that shows either every device or only the selected one; clicking the
/// header switches between the two.
private struct DeviceSection: View {
    @EnvironmentObject private var model: MixerModel
    let title: String
    let state: DeviceState
    @Binding var isExpanded: Bool

    var body: some View {
        let devices = model.menuDevices(state.direction)
        let selected = devices.first { $0.id == state.selectedID }
        let others = devices.filter { $0.id != state.selectedID }
        let showAll = isExpanded || selected == nil

        DisclosureHeader(title: title, isExpanded: showAll, isEnabled: !others.isEmpty && selected != nil) {
            withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
        }
        // The device in use always comes first; expanding reveals the others below it.
        if let selected { deviceRow(selected) }
        Collapsible(isExpanded: showAll) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(others) { deviceRow($0) }
            }
        }
    }

    private func deviceRow(_ device: AudioDevice) -> some View {
        let controls = model.headphones[device.uid]
        let expanded = controls != nil && expandedHeadphones.contains(device.uid)
        return VStack(alignment: .leading, spacing: 0) {
            DeviceRow(device: device, isSelected: device.id == state.selectedID, battery: controls?.battery,
                      isExpanded: controls == nil ? nil : expanded) {
                model.select(device)
            } toggleExpanded: {
                withAnimation(.easeInOut(duration: 0.22)) {
                    if expanded { expandedHeadphones.remove(device.uid) } else { expandedHeadphones.insert(device.uid) }
                }
            }
            if let controls {
                Collapsible(isExpanded: expanded) {
                    HeadphoneControls(device: device, state: controls)
                }
            }
        }
    }

    /// AirPods whose controls are showing. Starts collapsed each launch, like the system menu.
    @State private var expandedHeadphones: Set<String> = []
}

private struct DeviceRow: View {
    let device: AudioDevice
    let isSelected: Bool
    var battery: AirPodsControls.Battery?
    /// nil when the device has no controls to show.
    var isExpanded: Bool?
    let action: () -> Void
    var toggleExpanded: () -> Void = {}

    var body: some View {
        MenuRow(action: action) {
            HStack(spacing: 10) {
                CircleIcon(symbol: device.symbolName, tint: .accentColor, filled: isSelected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if let battery { BatteryLine(battery: battery, deviceSymbol: device.symbolName) }
                }
                Spacer(minLength: 0)
                // Room for the chevron drawn over the row.
                if isExpanded != nil { Color.clear.frame(width: 22, height: 1) }
            }
        }
        .overlay(alignment: .trailing) {
            if let isExpanded {
                Button(action: toggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, MenuMetrics.inset - 6)
                .help(isExpanded ? "Hide \(device.name) controls" : "Show \(device.name) controls")
                .accessibilityLabel(isExpanded ? "Hide \(device.name) controls" : "Show \(device.name) controls")
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "🎧 76%  ▭ 100%" under an AirPods name, like the system menu.
private struct BatteryLine: View {
    let battery: AirPodsControls.Battery
    let deviceSymbol: String

    var body: some View {
        HStack(spacing: 8) {
            if let left = battery.left, let right = battery.right, abs(left - right) > 5 {
                level("airpod.left", left)
                level("airpod.right", right)
            } else if let buds = battery.left.flatMap({ left in battery.right.map { min(left, $0) } ?? left }) ?? battery.right {
                level(deviceSymbol, buds)
            }
            if let single = battery.single { level("battery.100percent", single) }
            if let chargingCase = battery.chargingCase {
                level(deviceSymbol == "airpodspro" ? "airpodspro.chargingcase.wireless.fill" : "airpods.chargingcase.fill", chargingCase)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func level(_ symbol: String, _ percent: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10))
            Text("\(percent)%").monospacedDigit()
        }
    }
}

/// Listening Mode for one pair of AirPods.
private struct HeadphoneControls: View {
    @EnvironmentObject private var model: MixerModel
    let device: AudioDevice
    let state: AirPodsControls.State

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.offeredModes.isEmpty {
                ControlsHeader("Listening Mode")
                ForEach(state.offeredModes) { mode in
                    OptionRow(title: mode.title, symbol: mode.symbol, isChecked: state.listeningMode == mode) {
                        model.setListeningMode(mode, on: device)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
        .padding(.vertical, 3)
    }
}

private struct ControlsHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuMetrics.inset)
            .padding(.bottom, 2)
    }
}

/// A system symbol, including the private ones the system Sound menu uses for AirPods listening
/// modes (person.open.fill and friends), which `Image(systemName:)` doesn't load.
private struct MenuSymbol: View {
    let name: String

    var body: some View {
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            Image(systemName: name)
        } else {
            Image(_internalSystemName: name)
        }
    }
}

/// A choice with a checkmark on the left, like the system menu's AirPods options.
private struct OptionRow: View {
    let title: String
    let symbol: String
    let isChecked: Bool
    let action: () -> Void

    var body: some View {
        MenuRow(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(isChecked ? 1 : 0)
                    .frame(width: 14)
                MenuSymbol(name: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title).font(.system(size: 13))
            }
            .frame(height: 22)
        }
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}

/// Section title that expands or collapses its list, with a chevron on the right.
private struct DisclosureHeader: View {
    let title: String
    let isExpanded: Bool
    let isEnabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isEnabled {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.horizontal, MenuMetrics.inset - 5)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered && isEnabled ? Color.primary.opacity(0.09) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .padding(.horizontal, 5)
        .padding(.bottom, 2)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

// MARK: - Building blocks

/// "45%", or "Muted".
struct VolumeLabel: View {
    let volume: Double
    let isMuted: Bool

    var body: some View {
        Text(isMuted ? "Muted" : "\(Int((volume * 100).rounded()))%")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// Single-line text that fills the width it's offered. When the text is longer, it fades
/// out at the trailing edge, and while `scrolls` is on it loops through once per menu
/// session (`session`) like a ticker: the text moves left, a copy follows after a gap,
/// and the loop ends exactly where it started.
struct MarqueeText: View {
    let text: String
    let scrolls: Bool
    let session: Int

    private let fadeWidth: CGFloat = 18
    private let gap: CGFloat = 36
    private let pointsPerSecond: CGFloat = 30
    @State private var textWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isScrolling = false

    init(_ text: String, scrolls: Bool, session: Int) {
        self.text = text
        self.scrolls = scrolls
        self.session = session
    }

    private struct Run: Equatable {
        let text: String
        let session: Int
        let canScroll: Bool
    }

    var body: some View {
        let overflows = textWidth > availableWidth + 0.5
        HStack(spacing: gap) {
            Text(text)
                .lineLimit(1)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            if isScrolling {
                // The copy that slides in behind the original to close the loop.
                Text(text)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
        .offset(x: offset)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .clipped()
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: isScrolling ? fadeWidth : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: overflows ? fadeWidth : 0)
            }
        }
        .task(id: Run(text: text, session: session, canScroll: scrolls && overflows)) {
            offset = 0
            isScrolling = false
            guard scrolls, overflows else { return }
            let distance = textWidth + gap
            let duration = Double(distance / pointsPerSecond)
            do {
                try await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeIn(duration: 0.3)) { isScrolling = true }
                withAnimation(.linear(duration: duration)) { offset = -distance }
                try await Task.sleep(for: .seconds(duration))
            } catch {}
            // The copy now sits where the original started, so this jump is invisible.
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { offset = 0 }
            withAnimation(.easeOut(duration: 0.3)) { isScrolling = false }
        }
        .accessibilityLabel(text)
    }
}

/// Round mute toggle shown to the right of a volume slider.
struct MuteButton: View {
    let isMuted: Bool
    var symbol = "speaker.wave.2.fill"
    var mutedSymbol = "speaker.slash.fill"
    var size: CGFloat = 22
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isMuted ? Color.red.opacity(0.16) : Color.primary.opacity(hovered ? 0.15 : 0.08))
                Image(systemName: isMuted ? mutedSymbol : symbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(isMuted ? Color.red : Color.primary.opacity(0.75))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(isMuted ? "Unmute \(label)" : "Mute \(label)")
        .accessibilityLabel(isMuted ? "Unmute \(label)" : "Mute \(label)")
    }
}

struct CircleIcon: View {
    let symbol: String
    var tint: Color = .accentColor
    var filled = false

    var body: some View {
        ZStack {
            Circle()
                .fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary.opacity(0.1)))
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(filled ? Color.white : Color.primary.opacity(0.8))
        }
        .frame(width: MenuMetrics.iconSize, height: MenuMetrics.iconSize)
    }
}

/// A clickable row with the rounded hover highlight used by system menus.
struct MenuRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MenuMetrics.inset - 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovered ? Color.primary.opacity(0.09) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .onHover { hovered = $0 }
    }
}

private struct MenuActionRow: View {
    let title: String
    var isChecked: Bool? = nil
    let action: () -> Void

    var body: some View {
        MenuRow(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if isChecked == true {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 22)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuMetrics.inset)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }
}

private struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, MenuMetrics.inset)
            .padding(.vertical, 6)
    }
}
