import SwiftUI

/// The menu bar panel, laid out like the system Sound menu.
struct MenuContentView: View {
    @EnvironmentObject private var model: MixerModel
    /// Device lists start collapsed to the selected device every time the menu opens.
    @State private var outputExpanded: Bool
    @State private var inputExpanded: Bool

    /// `expanded` is for previews; the live menu always opens collapsed.
    private let collapsesOnOpen: Bool

    init(expanded: Bool = false) {
        _outputExpanded = State(initialValue: expanded)
        _inputExpanded = State(initialValue: expanded)
        collapsesOnOpen = !expanded
    }

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
                PermissionRow()
            }

            if model.apps.isEmpty {
                Text("No apps are playing audio")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, MenuMetrics.inset)
                    .padding(.vertical, 6)
            } else {
                AppList(apps: model.apps)
            }

            MenuSeparator()
            DeviceSection(title: "Output", state: model.output, isExpanded: $outputExpanded)

            MenuSeparator()
            DeviceSection(title: "Input", state: model.input, isExpanded: $inputExpanded)

            MenuSeparator()
            MenuActionRow(title: "Sound Settings…") { model.openSoundSettings() }
            MenuActionRow(title: "Open at Login", isChecked: model.launchAtLogin) {
                model.setLaunchAtLogin(!model.launchAtLogin)
            }
            MenuActionRow(title: "Quit Volumist") { NSApp.terminate(nil) }
        }
        .padding(.bottom, 6)
        .frame(width: MenuMetrics.width)
        .onAppear(perform: menuOpened)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            menuOpened()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            model.menuDidClose()
        }
    }

    private func menuOpened() {
        if collapsesOnOpen {
            outputExpanded = false
            inputExpanded = false
        }
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

    var body: some View {
        let state = model.output
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13))
                .frame(width: 16)
            MenuSlider(
                value: Binding(get: { state.muted ? 0 : state.volume }, set: { model.setVolume($0, .output) }),
                isEnabled: state.volumeSettable
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

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .opacity(app.isMuted ? 0.45 : 1)

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
                        FadingText(title)
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
                        controlSize: .small
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
        MenuRow(action: AudioCapturePermission.openPrivacySettings) {
            HStack(spacing: 10) {
                CircleIcon(symbol: "exclamationmark", tint: .orange, filled: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow Audio Capture")
                        .font(.system(size: 13))
                    Text("Needed to change per-app volume")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Devices

/// A device list that shows only the selected device until its header is clicked.
private struct DeviceSection: View {
    @EnvironmentObject private var model: MixerModel
    let title: String
    let state: DeviceState
    @Binding var isExpanded: Bool

    var body: some View {
        let others = state.devices.filter { $0.id != state.selectedID }
        let showAll = isExpanded || state.selected == nil

        DisclosureHeader(title: title, isExpanded: showAll, isEnabled: !others.isEmpty && state.selected != nil) {
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
        }
        ForEach(showAll ? state.devices : state.selected.map { [$0] } ?? []) { device in
            DeviceRow(device: device, isSelected: device.id == state.selectedID) {
                model.select(device)
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded = false }
            }
            .transition(.opacity)
        }
    }
}

private struct DeviceRow: View {
    let device: AudioDevice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        MenuRow(action: action) {
            HStack(spacing: 10) {
                CircleIcon(symbol: device.symbolName, tint: .accentColor, filled: isSelected)
                Text(device.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

/// Single-line text that fills the width it's offered and, when the text is longer,
/// fades out at the trailing edge instead of truncating with an ellipsis.
struct FadingText: View {
    let text: String
    private let fadeWidth: CGFloat = 18
    @State private var textWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0

    init(_ text: String) { self.text = text }

    var body: some View {
        let overflows = textWidth > availableWidth + 0.5
        Text(text)
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: overflows ? fadeWidth : 0)
                }
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
