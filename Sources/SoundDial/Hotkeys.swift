import Carbon.HIToolbox
import Foundation

/// Global hotkeys via Carbon `RegisterEventHotKey` (no Accessibility permission needed).
/// Volume keys auto-repeat while held.
@MainActor
enum Hotkeys {
    struct Binding {
        let keys: String
        let action: String
    }

    /// Shown in the routing window.
    static let reference: [Binding] = [
        .init(keys: "⌃⌥ ↑ / ↓", action: "Selected app volume ±5%"),
        .init(keys: "⌃⌥ ← / →", action: "Select previous / next app playing audio"),
        .init(keys: "⌃⌥ M", action: "Mute / unmute selected app"),
        .init(keys: "⌃⌥ 1 / 2 / 3", action: "Send selected app to output slot 1 / 2 / 3"),
        .init(keys: "⌃⌥ 0", action: "Send selected app back to the default output"),
        .init(keys: "⌃⌥⇧ 1 / 2 / 3", action: "Make slot 1 / 2 / 3 the default output"),
        .init(keys: "⌃⌥⇧ ↑ / ↓", action: "Volume of the selected app's output device ±5%"),
        .init(keys: "🔉 / 🔊 / 🔇", action: "Default output volume / mute, on outputs without their own volume"),
    ]

    private struct Entry {
        let repeats: Bool
        let handler: () -> Void
    }

    private static var entries: [UInt32: Entry] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    private static var repeatTimer: Timer?

    static func register(model: AppModel) {
        let ctrlOpt = controlKey | optionKey
        let ctrlOptShift = ctrlOpt | shiftKey

        add(kVK_UpArrow, ctrlOpt, repeats: true) { [weak model] in model?.nudgeSelected(0.05) }
        add(kVK_DownArrow, ctrlOpt, repeats: true) { [weak model] in model?.nudgeSelected(-0.05) }
        add(kVK_LeftArrow, ctrlOpt) { [weak model] in model?.cycleSelection(-1) }
        add(kVK_RightArrow, ctrlOpt) { [weak model] in model?.cycleSelection(1) }
        add(kVK_ANSI_M, ctrlOpt) { [weak model] in model?.toggleMuteSelected() }
        add(kVK_ANSI_0, ctrlOpt) { [weak model] in model?.routeSelected(slot: nil) }
        for (i, key) in [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3].enumerated() {
            add(key, ctrlOpt) { [weak model] in model?.routeSelected(slot: i) }
            add(key, ctrlOptShift) { [weak model] in model?.switchDefaultOutput(slot: i) }
        }
        add(kVK_UpArrow, ctrlOptShift, repeats: true) { [weak model] in model?.nudgeDeviceVolume(0.05) }
        add(kVK_DownArrow, ctrlOptShift, repeats: true) { [weak model] in model?.nudgeDeviceVolume(-0.05) }
    }

    private static func add(_ keyCode: Int, _ modifiers: Int, repeats: Bool = false, _ handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5344_6C31), id: id) // 'SDl1'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            audioLog.error("Hotkey \(keyCode) registration failed: \(status) (already used by another app?)")
            return
        }
        refs.append(ref)
        entries[id] = Entry(repeats: repeats, handler: handler)
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hotKeyID.id
            MainActor.assumeIsolated { Hotkeys.handle(id: id, pressed: pressed) }
            return noErr
        }, types.count, &types, nil, nil)
    }

    private static func handle(id: UInt32, pressed: Bool) {
        repeatTimer?.invalidate()
        repeatTimer = nil
        guard pressed, let entry = entries[id] else { return }
        entry.handler()
        guard entry.repeats else { return }
        // Hold to keep adjusting: start repeating after a short delay.
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            MainActor.assumeIsolated {
                repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
                    MainActor.assumeIsolated { entry.handler() }
                }
            }
        }
    }
}
