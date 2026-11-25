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

// MARK: - Switching

struct SwitchingSettingsView: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        Form {
            Section {
                if delayedApps.isEmpty {
                    Text("No delays. Any app takes your headphones back as soon as it plays.")
                        .foregroundStyle(.secondary)
                }
                ForEach(delayedApps) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: app.icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 20, height: 20)
                        Text(app.name)
                        Spacer()
                        Picker("Delay for \(app.name)", selection: Binding(
                            get: { model.switchDelays[app.id] ?? MixerModel.switchDelayChoices[0] },
                            set: { model.setSwitchDelay($0, appID: app.id) }
                        )) {
                            ForEach(MixerModel.switchDelayChoices, id: \.self) { seconds in
                                Text(Self.label(seconds)).tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            model.setSwitchDelay(nil, appID: app.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove the delay for \(app.name)")
                    }
                }
                Menu("Add App") {
                    ForEach(addableApps) { app in
                        Button(app.name) { model.setSwitchDelay(MixerModel.switchDelayChoices[0], appID: app.id) }
                    }
                }
                .disabled(addableApps.isEmpty)
                .fixedSize()
            } header: {
                Text("Headphone Switching")
            } footer: {
                Text("When AirPods or other headphones move to another device, Volumist takes them back as soon as an app plays on this Mac, like macOS does on its own. Apps listed here must play for the chosen time first, so short sounds like message alerts don't take your headphones. macOS alert sounds never do. Applies while the Volumist audio driver is in use.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var delayedApps: [KnownApp] {
        model.knownApps.filter { model.switchDelays[$0.id] != nil }
    }

    private var addableApps: [KnownApp] {
        model.knownApps.filter { model.switchDelays[$0.id] == nil && !$0.id.hasPrefix("pid:") }
    }

    private static func label(_ seconds: Double) -> String {
        seconds < 1 ? "0.5 seconds" : seconds == 1 ? "1 second" : "\(Int(seconds)) seconds"
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: MixerModel
    @AppStorage(Preferences.mainVolumeStep) private var mainVolumeStep = 0.0
    @AppStorage(Preferences.appVolumeStep) private var appVolumeStep = 0.0
    @AppStorage(Preferences.showOutputSection) private var showOutputSection = true
    @AppStorage(Preferences.showInputSection) private var showInputSection = true
    @AppStorage(Preferences.audioEngine) private var audioEngine = Preferences.engineDriver
    @State private var confirming: DriverAction?

    private enum DriverAction: Identifiable {
        case install, update, uninstall
        var id: Self { self }
    }

    var body: some View {
        Form {
            Section {
                Picker("Change app volumes with", selection: $audioEngine) {
                    Text("Volumist audio driver").tag(Preferences.engineDriver)
                    Text("Audio capture").tag(Preferences.engineCapture)
                }
                .onChange(of: audioEngine) { model.engineChoiceChanged() }
                LabeledContent("Volumist audio driver") {
                    HStack(spacing: 8) {
                        if model.driverBusy { ProgressView().controlSize(.small) }
                        Text(driverStatusText).foregroundStyle(.secondary)
                        if let action = driverAction {
                            Button(actionTitle(action)) { confirming = action }
                                .disabled(model.driverBusy)
                        }
                    }
                }
                if let error = model.driverError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Audio Engine")
            } footer: {
                Text(engineStatus)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Volume Sliders") {
                StepPicker(title: "Main volume", selection: $mainVolumeStep)
                StepPicker(title: "App volume", selection: $appVolumeStep)
            }
            Section("Menu") {
                Toggle("Show Output section", isOn: $showOutputSection)
                Toggle("Show Input section", isOn: $showInputSection)
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
        .onAppear {
            model.refreshLaunchAtLogin()
            model.refreshDriverStatus()
        }
        .alert(item: $confirming) { action in
            Alert(
                title: Text(alertTitle(action)),
                message: Text(alertMessage(action)),
                primaryButton: action == .uninstall
                    ? .destructive(Text(actionTitle(action).replacingOccurrences(of: "…", with: ""))) { perform(action) }
                    : .default(Text(actionTitle(action).replacingOccurrences(of: "…", with: ""))) { perform(action) },
                secondaryButton: .cancel()
            )
        }
    }

    private var driverStatusText: String {
        if model.driverBusy { return "Working…" }
        switch model.driverStatus {
        case .notInstalled: return "Not installed"
        case .installed(let version): return "Installed (\(version))"
        case .updateAvailable(let installed, _): return "Update available (installed \(installed))"
        case .notBundled: return "Not available in this build"
        }
    }

    private var driverAction: DriverAction? {
        switch model.driverStatus {
        case .notInstalled: return .install
        case .updateAvailable: return .update
        case .installed: return .uninstall
        case .notBundled: return nil
        }
    }

    private func actionTitle(_ action: DriverAction) -> String {
        switch action {
        case .install: return "Install…"
        case .update: return "Update…"
        case .uninstall: return "Uninstall…"
        }
    }

    private func alertTitle(_ action: DriverAction) -> String {
        switch action {
        case .install: return "Install the Volumist audio driver?"
        case .update: return "Update the Volumist audio driver?"
        case .uninstall: return "Remove the Volumist audio driver?"
        }
    }

    private func alertMessage(_ action: DriverAction) -> String {
        let restart = "macOS will ask for an administrator password. Core Audio then restarts, so all sound stops for a moment."
        switch action {
        case .install, .update:
            return "With the driver, Volumist changes each app's volume without recording audio: no permission prompt and no recording indicator. " + restart
        case .uninstall:
            return restart + " Volumist then uses audio capture, which needs the System Audio Recording permission and shows the recording indicator."
        }
    }

    private func perform(_ action: DriverAction) {
        if action == .uninstall { model.uninstallDriver() } else { model.installDriver() }
    }

    private var engineStatus: String {
        if !DriverEngine.isInstalled {
            return "The Volumist audio driver isn't installed, so audio capture is used. It needs the System Audio Recording permission and shows the recording indicator while active."
        }
        if model.usingDriver {
            return "Apps play through the Volumist device, which applies each app's volume. No recording permission, no recording indicator."
        }
        return "Audio capture needs the System Audio Recording permission and shows the recording indicator while an app's volume is changed."
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
