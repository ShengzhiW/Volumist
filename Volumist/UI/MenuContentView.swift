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
            Text("Sound")
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, MenuMetrics.inset)
                .padding(.top, 11)
                .padding(.bottom, 9)

            DeviceVolumeRow(state: model.output)

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
            DeviceVolumeRow(state: model.input)
                .padding(.top, 6)

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

// MARK: - Device volume

private struct DeviceVolumeRow: View {
    @EnvironmentObject private var model: MixerModel
    let state: DeviceState

    var body: some View {
        let isOutput = state.direction == .output
        HStack(spacing: 8) {
            Image(systemName: isOutput
                  ? (state.muted ? "speaker.slash.fill" : "speaker.fill")
                  : (state.muted ? "mic.slash.fill" : "mic.fill"))
                .font(.system(size: isOutput ? 13 : 11))
                .frame(width: 16)
                .contentShape(Rectangle())
                .onTapGesture { model.toggleMute(state.direction) }
                .help(state.muted ? "Unmute" : "Mute")
            MenuSlider(
                value: Binding(get: { state.muted ? 0 : state.volume }, set: { model.setVolume($0, state.direction) }),
                isEnabled: state.volumeSettable
            )
            Image(systemName: isOutput ? "speaker.wave.3.fill" : "mic.fill")
                .font(.system(size: isOutput ? 13 : 15))
                .frame(width: 22)
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.horizontal, MenuMetrics.inset)
        .padding(.bottom, 8)
        .accessibilityLabel(isOutput ? "Output volume" : "Input volume")
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
    @State private var iconHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button { model.toggleMute(for: app.id) } label: {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .opacity(app.isMuted ? 0.45 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if app.isMuted || iconHovered {
                            Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.fill")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(app.isMuted ? Color.red : Color.black.opacity(0.55)))
                                .offset(x: 3, y: 3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .onHover { iconHovered = $0 }
            .help(app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if app.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                    }
                    Spacer(minLength: 4)
                    Text(app.isMuted ? "Muted" : "\(Int((app.volume * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                MenuSlider(
                    value: Binding(get: { app.isMuted ? 0 : app.volume }, set: { model.setVolume($0, for: app.id) }),
                    isDimmed: app.isMuted,
                    trackHeight: 5,
                    knobSize: CGSize(width: 20, height: 13)
                )
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
