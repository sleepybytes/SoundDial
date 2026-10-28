import SwiftUI
import UniformTypeIdentifiers

struct RoutingView: View {
    var body: some View {
        TabView {
            RulesTab().tabItem { Label("Apps", systemImage: "slider.horizontal.3") }
            HotkeysTab().tabItem { Label("Hotkeys", systemImage: "keyboard") }
        }
        .padding()
        .frame(minWidth: 820, minHeight: 440)
    }
}

private struct Row: Identifiable {
    let id: String
}

private struct RulesTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.permission != .authorized {
                PermissionBanner()
            }
            Text("Choose where each app plays and how loud. Mic rules switch the system input while that app is recording.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(model.devices.outputs.filter { model.devices.isUnavailable($0.uid) }) { device in
                WarningText("\(device.name) can't play audio right now. Apps sent there play on the default output until it works again.")
            }

            Table(model.routingBundleIDs.map(Row.init)) {
                TableColumn("App") { row in AppCell(bundleID: row.id) }
                    .width(min: 160, ideal: 200)
                TableColumn("Output") { row in OutputCell(bundleID: row.id) }
                    .width(min: 160, ideal: 190)
                TableColumn("Volume") { row in
                    VolumeSlider(value: model.volume(row.id), muted: model.isMuted(row.id), symbol: "speaker.wave.2",
                                 onMute: { model.setMuted(row.id, !model.isMuted(row.id)) }) {
                        model.setVolume(row.id, $0)
                    }
                }
                .width(min: 180, ideal: 220)
                TableColumn("Mic while recording") { row in InputCell(bundleID: row.id) }
                    .width(min: 150, ideal: 180)
                TableColumn("") { row in
                    if model.rules.rule(row.id) != nil {
                        Button {
                            model.removeRule(row.id)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("Reset to defaults")
                    }
                }
                .width(28)
            }

            HStack {
                Button("Add App…", action: addApp)
                Spacer()
                Text("Apps appear here once they use audio. Rules are remembered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(model.addApp(at:))
    }
}

private struct AppCell: View {
    @Environment(AppModel.self) private var model
    let bundleID: String

    var body: some View {
        let app = model.processes.app(bundleID)
        HStack(spacing: 8) {
            Image(nsImage: AppIcons.icon(bundleID)).resizable().frame(width: 18, height: 18)
            Text(model.name(bundleID)).lineLimit(1)
            if app?.isPlaying == true {
                Image(systemName: "waveform").foregroundStyle(.green).font(.caption)
            }
            if app?.isRecording == true {
                Image(systemName: "mic.fill").foregroundStyle(.red).font(.caption)
            }
        }
    }
}

private struct OutputCell: View {
    @Environment(AppModel.self) private var model
    let bundleID: String

    var body: some View {
        let uid = model.outputUID(bundleID)
        HStack(spacing: 4) {
            Picker("", selection: Binding<String?>(get: { uid }, set: { model.setOutput(bundleID, $0) })) {
                Text("System default").tag(String?.none)
                Divider()
                ForEach(model.devices.outputs) { device in
                    DeviceLabel(device: device, unavailable: model.devices.isUnavailable(device.uid)).tag(Optional(device.uid))
                }
                if let uid, model.devices.output(uid: uid) == nil {
                    Text("Disconnected device").tag(Optional(uid))
                }
            }
            .labelsHidden()
            if let note = model.fallbackNote(bundleID) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(note)
            }
        }
    }
}

private struct InputCell: View {
    @Environment(AppModel.self) private var model
    let bundleID: String

    var body: some View {
        let uid = model.inputUID(bundleID)
        Picker("", selection: Binding<String?>(get: { uid }, set: { model.setInput(bundleID, $0) })) {
            Text("Don't change").tag(String?.none)
            Divider()
            ForEach(model.devices.inputs) { device in
                Label(device.name, systemImage: device.symbol).tag(Optional(device.uid))
            }
            if let uid, model.devices.input(uid: uid) == nil {
                Text("Disconnected device").tag(Optional(uid))
            }
        }
        .labelsHidden()
    }
}

private struct HotkeysTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var rules = model.rules
        Form {
            Section("Output slots") {
                ForEach(0..<3, id: \.self) { i in
                    Picker("Slot \(i + 1)  (⌃⌥\(i + 1) / ⌃⌥⇧\(i + 1))", selection: $rules.slots[i]) {
                        Text("None").tag(String?.none)
                        ForEach(model.devices.outputs) { device in
                            DeviceLabel(device: device, unavailable: model.devices.isUnavailable(device.uid)).tag(Optional(device.uid))
                        }
                        if let uid = rules.slots[i], model.devices.output(uid: uid) == nil {
                            Text("Disconnected device").tag(Optional(uid))
                        }
                    }
                }
            }
            Section("Shortcuts") {
                ForEach(Hotkeys.reference, id: \.keys) { binding in
                    LabeledContent(binding.action) {
                        Text(binding.keys).font(.body.monospaced())
                    }
                }
                Text("The selected app follows the frontmost app; ⌃⌥←/→ picks another one that's playing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch SoundDial at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}
