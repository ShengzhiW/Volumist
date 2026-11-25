import SwiftUI

// MARK: - Apps

struct AppsSettingsView: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose which apps appear in the menu. Hidden apps keep their volume settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(model.knownApps) { app in
                HStack(spacing: 10) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        Text(app.isRunning ? app.id : "\(app.id) · Not running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Toggle("Show \(app.name) in the menu", isOn: Binding(
                        get: { !model.hiddenApps.contains(app.id) },
                        set: { model.setHidden(!$0, appID: app.id) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Show in menu")
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if model.knownApps.isEmpty {
                    Text("No apps have used audio yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }
}

// MARK: - Devices

struct DevicesSettingsView: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        Form {
            Section {
                rows(.output)
            } header: {
                Text("Output")
            } footer: {
                Text("Hidden devices don't appear in the menu. The device in use always does.")
                    .foregroundStyle(.secondary)
            }
            Section("Input") {
                rows(.input)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func rows(_ direction: AudioDirection) -> some View {
        let selectedID = direction == .output ? model.output.selectedID : model.input.selectedID
        ForEach(model.deviceListings(direction)) { listing in
            let inUse = listing.device?.id == selectedID
            HStack(spacing: 10) {
                Image(systemName: listing.device?.symbolName ?? (direction == .output ? "speaker.wave.2.fill" : "mic.fill"))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(listing.name)
                    if listing.device == nil {
                        Text("Not connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if inUse {
                    Text("In use")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show \(listing.name) in the menu", isOn: Binding(
                    get: { model.hiddenDevices[listing.id] == nil },
                    set: { model.setHidden(!$0, listing: listing) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Show in menu")
            }
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: MixerModel
    @AppStorage(Preferences.mainVolumeStep) private var mainVolumeStep = 0.0
    @AppStorage(Preferences.appVolumeStep) private var appVolumeStep = 0.0
    @AppStorage(Preferences.showOutputSection) private var showOutputSection = true
    @AppStorage(Preferences.showInputSection) private var showInputSection = true
    @AppStorage(Preferences.pauseTapsWhenSilent) private var pauseTapsWhenSilent = true

    var body: some View {
        Form {
            Section("Volume Sliders") {
                StepPicker(title: "Main volume", selection: $mainVolumeStep)
                StepPicker(title: "App volume", selection: $appVolumeStep)
            }
            Section("Menu") {
                Toggle("Show Output section", isOn: $showOutputSection)
                Toggle("Show Input section", isOn: $showInputSection)
            }
            Section {
                Toggle("Stop capturing apps that aren't playing", isOn: $pauseTapsWhenSilent)
                    .onChange(of: pauseTapsWhenSilent) { model.tapPausingChanged() }
            } header: {
                Text("Audio Capture")
            } footer: {
                Text("Volumist stops capturing an app a few seconds after it goes quiet, so the recording indicator goes away, and starting playback on the Mac takes your AirPods back from an iPhone like it does without Volumist. When the app plays again, its first moment may play at its normal volume before yours applies. Turn off to keep capturing all the time.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Open at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshLaunchAtLogin() }
    }
}

private struct StepPicker: View {
    let title: String
    @Binding var selection: Double

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Preferences.volumeSteps, id: \.value) { step in
                Text(step.label).tag(step.value)
            }
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("Volumist")
                    .font(.title2.weight(.semibold))
                Text(version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("A per-app volume mixer for the menu bar. Each app's audio is captured with a Core Audio process tap and played back at the volume you choose.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            Link("View on GitHub", destination: URL(string: "https://github.com/ShengzhiW/Volumist")!)
                .font(.callout)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 28)
        .frame(width: 480)
    }
}
