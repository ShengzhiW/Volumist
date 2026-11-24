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

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: MixerModel
    @AppStorage(Preferences.mainVolumeStep) private var mainVolumeStep = 0.0
    @AppStorage(Preferences.appVolumeStep) private var appVolumeStep = 0.0
    @AppStorage(Preferences.showOutputSection) private var showOutputSection = true
    @AppStorage(Preferences.showInputSection) private var showInputSection = true

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
