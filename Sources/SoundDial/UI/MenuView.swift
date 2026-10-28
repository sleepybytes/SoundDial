import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.permission != .authorized {
                PermissionBanner()
            }

            section("Output") {
                DevicePicker(devices: model.devices.outputs, selection: model.devices.defaultOutputUID,
                             unavailable: model.devices.unavailableUIDs) {
                    model.devices.setDefaultOutput($0)
                }
                if let device = model.devices.defaultOutput, model.devices.isUnavailable(device.uid) {
                    WarningText("\(device.name) can't play audio right now. Check its speakers or cable, or pick another output.")
                }
                if let uid = model.devices.defaultOutputUID {
                    VolumeSlider(value: model.devices.volume(uid), muted: model.devices.isSoftMuted(uid), symbol: "speaker.wave.2",
                                 onMute: model.defaultOutputLacksVolume ? { model.devices.toggleSoftMute(uid) } : nil) {
                        model.devices.setVolume(uid, $0)
                    }
                }
                if model.needsAccessibilityForVolumeKeys {
                    AccessibilityBanner()
                }
            }

            section("Input") {
                DevicePicker(devices: model.devices.inputs, selection: model.devices.defaultInputUID) {
                    model.devices.setDefaultInput($0)
                }
            }

            Divider()

            section("Apps") {
                let apps = model.menuApps
                if apps.isEmpty {
                    Text("No apps are playing audio").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(apps) { app in AppRow(app: app) }
                }
            }

            Divider()

            HStack {
                Button("Configure…") {
                    openWindow(id: "routing")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct AppRow: View {
    @Environment(AppModel.self) private var model
    let app: AudioApp

    var body: some View {
        let id = app.bundleID
        let selected = model.selectedBundleID == id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: AppIcons.icon(id)).resizable().frame(width: 20, height: 20)
                Text(app.name).lineLimit(1)
                if app.isRecording {
                    Image(systemName: "mic.fill").foregroundStyle(.red).font(.caption)
                }
                Spacer()
                OutputMenu(bundleID: id)
            }
            VolumeSlider(value: model.volume(id), muted: model.isMuted(id), symbol: "speaker.wave.2",
                         onMute: { model.setMuted(id, !model.isMuted(id)) }) {
                model.setVolume(id, $0)
            }
            if let note = model.fallbackNote(id) {
                WarningText(note)
            }
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedBundleID = id }
    }
}

/// Compact menu showing where an app plays, with the option to send it elsewhere.
struct OutputMenu: View {
    @Environment(AppModel.self) private var model
    let bundleID: String

    var body: some View {
        let current = model.outputUID(bundleID)
        let effective = model.effectiveOutput(bundleID)
        let note = model.fallbackNote(bundleID)
        Menu {
            Button {
                model.setOutput(bundleID, nil)
            } label: {
                Label("System default", systemImage: current == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(model.devices.outputs) { device in
                Button {
                    model.setOutput(bundleID, device.uid)
                } label: {
                    Label(model.devices.isUnavailable(device.uid) ? "\(device.name) (can't play)" : device.name,
                          systemImage: current == device.uid ? "checkmark" : device.symbol)
                }
            }
        } label: {
            Label(effective?.name ?? "—", systemImage: note != nil ? "exclamationmark.triangle.fill" : effective?.symbol ?? "speaker.slash")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(note ?? (current == nil ? "Following the system default output" : "Routed to \(effective?.name ?? "a disconnected device")"))
    }
}

struct DevicePicker: View {
    let devices: [AudioDevice]
    let selection: String?
    var unavailable: Set<String> = []
    let onSelect: (String) -> Void

    var body: some View {
        Picker("", selection: Binding(get: { selection ?? "" }, set: { onSelect($0) })) {
            ForEach(devices) { device in
                DeviceLabel(device: device, unavailable: unavailable.contains(device.uid)).tag(device.uid)
            }
        }
        .labelsHidden()
    }
}

struct DeviceLabel: View {
    let device: AudioDevice
    let unavailable: Bool

    var body: some View {
        if unavailable {
            Label("\(device.name) (can't play)", systemImage: "exclamationmark.triangle")
        } else {
            Label(device.name, systemImage: device.symbol)
        }
    }
}

struct WarningText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct VolumeSlider: View {
    let value: Float
    let muted: Bool
    let symbol: String
    var onMute: (() -> Void)?
    let onChange: (Float) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onMute?()
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : symbol)
                    .frame(width: 18)
                    .foregroundStyle(muted ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(onMute == nil)
            Slider(value: Binding(get: { Double(muted ? 0 : value) }, set: { onChange(Float($0)) }), in: 0...1)
                .controlSize(.small)
            Text("\(Int(((muted ? 0 : value) * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

struct AccessibilityBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(model.devices.defaultOutput?.name ?? "This output") has no volume control of its own. Allow Accessibility so your keyboard's volume keys work on it.",
                  systemImage: "keyboard")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow Accessibility…") { model.requestAccessibility() }
                .controlSize(.small)
        }
        .padding(8)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PermissionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("SoundDial needs System Audio Recording access to change per-app volume and routing.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.permission == .undetermined {
                    Button("Allow…") { model.requestPermission() }
                } else {
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(AudioCapturePermission.settingsURL) }
                }
                Button("Check again") { model.recheckPermission() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}
