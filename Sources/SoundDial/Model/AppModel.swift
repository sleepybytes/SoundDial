import AppKit
import CoreAudio
import Observation
import ServiceManagement

/// Coordinates devices, running apps, rules and the routing engine; the UI and hotkeys call into this.
@Observable @MainActor
final class AppModel {
    let devices = DeviceManager()
    let processes = ProcessMonitor()
    let rules = RuleStore()

    private(set) var permission = AudioCapturePermission.status
    /// The app hotkeys act on: follows the frontmost app, ⌃⌥←/→ overrides it.
    var selectedBundleID: String?
    private(set) var tappedBundleIDs: Set<String> = []

    /// Keyboard volume keys drive SoundDial's volume on outputs that have no volume control of their own.
    var useVolumeKeys = UserDefaults.standard.object(forKey: "useVolumeKeys") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(useVolumeKeys, forKey: "useVolumeKeys")
            if useVolumeKeys { mediaKeys?.start() }
        }
    }
    /// True once the volume-key event tap is running (Accessibility has been granted).
    private(set) var volumeKeysInstalled = false

    @ObservationIgnored private let engine = RoutingEngine()
    @ObservationIgnored private let inputSwitcher = InputSwitcher()
    @ObservationIgnored private var mediaKeys: MediaKeys?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        devices.onChange = { [weak self] in self?.reconcile() }
        processes.onChange = { [weak self] in self?.reconcile() }
        assignDefaultSlots()

        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, front != Bundle.main.bundleIdentifier {
            selectedBundleID = front
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if let bundleID, bundleID != Bundle.main.bundleIdentifier { self?.selectedBundleID = bundleID }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.teardown() }
        })
        // Picks up idle-grace expiry and anything a listener missed.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }

        Hotkeys.register(model: self)
        mediaKeys = MediaKeys(
            shouldHandle: { [weak self] in self?.volumeKeysActive ?? false },
            onKey: { [weak self] key, fine in self?.handleVolumeKey(key, fine: fine) },
            onInstall: { [weak self] in self?.volumeKeysInstalled = true })
        if useVolumeKeys {
            mediaKeys?.start()
            // Ask for Accessibility once, the first time the default output can't do volume itself.
            if needsAccessibilityForVolumeKeys && !UserDefaults.standard.bool(forKey: "askedAccessibility") {
                UserDefaults.standard.set(true, forKey: "askedAccessibility")
                mediaKeys?.requestAccess()
            }
        }
        // Check outputs that rules send apps to, so a dead one is flagged before those apps play.
        for uid in Set(rules.rules.values.compactMap(\.outputUID)) { devices.probe(uid) }
        if permission == .undetermined { requestPermission() }
        reconcile()
    }

    func reconcile() {
        engine.reconcile(apps: processes.apps, rules: rules, devices: devices, enabled: permission == .authorized)
        inputSwitcher.update(apps: processes.apps, rules: rules, devices: devices)
        let tapped = Set(engine.taps.keys)
        if tapped != tappedBundleIDs { tappedBundleIDs = tapped }
    }

    // MARK: Permission

    func requestPermission() {
        AudioCapturePermission.request { [weak self] _ in
            guard let self else { return }
            permission = AudioCapturePermission.status
            reconcile()
        }
    }

    func recheckPermission() {
        permission = AudioCapturePermission.status
        reconcile()
    }

    // MARK: Per-app settings

    func name(_ bundleID: String) -> String {
        processes.app(bundleID)?.name
            ?? rules.rule(bundleID)?.name
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? bundleID
    }

    func volume(_ bundleID: String) -> Float { rules.rule(bundleID)?.volume ?? 1 }
    func isMuted(_ bundleID: String) -> Bool { rules.rule(bundleID)?.muted ?? false }
    func outputUID(_ bundleID: String) -> String? { rules.rule(bundleID)?.outputUID }
    func inputUID(_ bundleID: String) -> String? { rules.rule(bundleID)?.inputUID }

    func setVolume(_ bundleID: String, _ value: Float) {
        rules.update(bundleID, name: name(bundleID)) {
            $0.volume = min(max(value, 0), 1)
            if value > 0 { $0.muted = false }
        }
        reconcile()
    }

    func setMuted(_ bundleID: String, _ muted: Bool) {
        rules.update(bundleID, name: name(bundleID)) { $0.muted = muted }
        reconcile()
    }

    func setOutput(_ bundleID: String, _ uid: String?) {
        rules.update(bundleID, name: name(bundleID)) { $0.outputUID = uid }
        if let uid { devices.probe(uid) }
        reconcile()
    }

    /// Why an app isn't playing where it was sent, if it isn't.
    func fallbackNote(_ bundleID: String) -> String? {
        guard let uid = outputUID(bundleID), let wanted = devices.output(uid: uid), devices.isUnavailable(uid) else { return nil }
        let actual = devices.defaultOutput?.name ?? "the default output"
        return "\(wanted.name) can't play audio right now — using \(actual)"
    }

    func setInput(_ bundleID: String, _ uid: String?) {
        rules.update(bundleID, name: name(bundleID)) { $0.inputUID = uid }
        reconcile()
    }

    func addApp(at url: URL) {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        rules.update(bundleID, name: name) { _ in }
    }

    func removeRule(_ bundleID: String) {
        rules.remove(bundleID)
        reconcile()
    }

    /// Apps shown in the menu: everything playing, plus anything with a rule that's running.
    var menuApps: [AudioApp] {
        processes.apps.filter { app in
            app.isPlaying || app.bundleID == selectedBundleID && rules.rule(app.bundleID) != nil || tappedBundleIDs.contains(app.bundleID)
        }
    }

    /// Rows for the routing window: running audio apps and saved rules.
    var routingBundleIDs: [String] {
        var ids = processes.apps
            .filter { app in
                rules.rule(app.bundleID) != nil
                    || NSRunningApplication(processIdentifier: app.pid)?.activationPolicy == .regular
            }
            .map(\.bundleID)
        for id in rules.rules.keys where !ids.contains(id) { ids.append(id) }
        return ids.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }

    func effectiveOutput(_ bundleID: String) -> AudioDevice? {
        devices.effectiveOutput(preferredUID: outputUID(bundleID))
    }

    // MARK: Hotkey actions

    func nudgeSelected(_ delta: Float) {
        guard let id = selectedBundleID else { return }
        let base = isMuted(id) ? 0 : volume(id)
        setVolume(id, (base + delta).rounded(toStep: 0.05))
        showAppHUD(id)
    }

    func toggleMuteSelected() {
        guard let id = selectedBundleID else { return }
        setMuted(id, !isMuted(id))
        showAppHUD(id)
    }

    func cycleSelection(_ direction: Int) {
        let playing = processes.apps.filter(\.isPlaying).map(\.bundleID)
        let candidates = playing.isEmpty ? routingBundleIDs : playing
        guard !candidates.isEmpty else { return }
        let index = selectedBundleID.flatMap { candidates.firstIndex(of: $0) }
        let next = index.map { ($0 + direction + candidates.count) % candidates.count } ?? 0
        selectedBundleID = candidates[next]
        showAppHUD(candidates[next])
    }

    func routeSelected(slot: Int?) {
        guard let id = selectedBundleID else { return }
        let uid = slot.flatMap { rules.slots.indices.contains($0) ? rules.slots[$0] : nil }
        if slot != nil && devices.output(uid: uid) == nil { return }
        setOutput(id, uid)
        showAppHUD(id)
    }

    func switchDefaultOutput(slot: Int) {
        guard rules.slots.indices.contains(slot), let uid = rules.slots[slot], let device = devices.output(uid: uid) else { return }
        devices.setDefaultOutput(uid)
        HUD.shared.show(icon: nil, symbol: device.symbol, title: device.name,
                        subtitle: devices.isUnavailable(uid) ? "⚠︎ Can't play audio right now" : "Default output",
                        level: devices.volume(uid), muted: false)
    }

    func nudgeDeviceVolume(_ delta: Float) {
        let device = selectedBundleID.flatMap { effectiveOutput($0) } ?? devices.defaultOutput
        guard let device else { return }
        devices.setVolume(device.uid, (devices.volume(device.uid) + delta).rounded(toStep: 0.05))
        HUD.shared.show(icon: nil, symbol: device.symbol, title: device.name,
                        subtitle: devices.hasHardwareVolume(device.uid) ? "Device volume" : "Device volume (software)",
                        level: devices.volume(device.uid), muted: false)
    }

    // MARK: Keyboard volume keys

    /// The default output has no volume control of its own, so macOS can't use the volume keys on it.
    var defaultOutputLacksVolume: Bool {
        guard let uid = devices.defaultOutputUID else { return false }
        return !devices.hasHardwareVolume(uid)
    }

    /// Software volume needs the audio permission; without it, leave the keys to macOS.
    var volumeKeysActive: Bool { useVolumeKeys && defaultOutputLacksVolume && permission == .authorized }

    var needsAccessibilityForVolumeKeys: Bool {
        useVolumeKeys && defaultOutputLacksVolume && !volumeKeysInstalled
    }

    func requestAccessibility() {
        mediaKeys?.requestAccess()
        NSWorkspace.shared.open(MediaKeys.settingsURL)
    }

    func handleVolumeKey(_ key: MediaKeys.Key, fine: Bool) {
        guard let device = devices.defaultOutput else { return }
        let uid = device.uid
        let step: Float = fine ? 1 / 64 : 1 / 16
        switch key {
        case .mute:
            devices.toggleSoftMute(uid)
        case .up, .down:
            let base = devices.levelBeforeMute(uid) ?? devices.volume(uid)
            let target = base + (key == .up ? step : -step)
            devices.setVolume(uid, min(max((target / step).rounded() * step, 0), 1))
        }
        HUD.shared.show(icon: nil, symbol: device.symbol, title: device.name, subtitle: "Volume (SoundDial)",
                        level: devices.volume(uid), muted: devices.isSoftMuted(uid))
    }

    private func showAppHUD(_ bundleID: String) {
        let device = effectiveOutput(bundleID)
        HUD.shared.show(icon: AppIcons.icon(bundleID), symbol: nil, title: name(bundleID),
                        subtitle: fallbackNote(bundleID).map { "⚠︎ \($0)" } ?? device.map { "→ \($0.name)" } ?? "",
                        level: volume(bundleID), muted: isMuted(bundleID))
    }

    // MARK: Slots & login item

    private func assignDefaultSlots() {
        guard rules.slots.allSatisfy({ $0 == nil }) else { return }
        let outs = devices.outputs
        let builtIn = outs.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
        let headphones = outs.first { [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains($0.transport) }
        let display = outs.first { [kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI].contains($0.transport) }
        rules.slots = [builtIn?.uid, headphones?.uid, display?.uid]
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                audioLog.error("Login item: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension Float {
    func rounded(toStep step: Float) -> Float {
        min(max((self / step).rounded() * step, 0), 1)
    }
}
