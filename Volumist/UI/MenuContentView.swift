import SwiftUI

/// The menu bar panel, laid out like the system Sound menu.
struct MenuContentView: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sound")
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, MenuMetrics.inset)
                .padding(.top, 11)
                .padding(.bottom, 9)

            MasterVolumeRow()

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
            SectionHeader("Output")
            ForEach(model.devices) { device in
                DeviceRow(device: device, isSelected: device.id == model.defaultOutputID) {
                    model.selectOutput(device)
                }
            }

            MenuSeparator()
            MenuActionRow(title: "Sound Settings…") { model.openSoundSettings() }
            MenuActionRow(title: "Open at Login", isChecked: model.launchAtLogin) {
                model.setLaunchAtLogin(!model.launchAtLogin)
            }
            MenuActionRow(title: "Quit Volumist") { NSApp.terminate(nil) }
        }
        .padding(.bottom, 6)
        .frame(width: MenuMetrics.width)
        .onAppear { model.menuWillOpen() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.menuWillOpen()
        }
    }
}

enum MenuMetrics {
    static let width: CGFloat = 310
    static let inset: CGFloat = 14
    static let iconSize: CGFloat = 26
}

// MARK: - Master volume

private struct MasterVolumeRow: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.outputMuted ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 13))
                .frame(width: 16)
                .contentShape(Rectangle())
                .onTapGesture { model.toggleOutputMute() }
            MenuSlider(
                value: Binding(get: { model.outputMuted ? 0 : model.outputVolume }, set: { model.setOutputVolume($0) }),
                isEnabled: model.outputVolumeSettable
            )
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 13))
                .frame(width: 22)
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.horizontal, MenuMetrics.inset)
        .padding(.bottom, 8)
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

// MARK: - Output devices

private struct DeviceRow: View {
    let device: OutputDevice
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
