import AppKit
import ApplicationServices

/// Takes over the keyboard volume and mute keys while the default output has no volume control of
/// its own (e.g. a DisplayPort monitor), driving SoundDial's software volume instead. On every other
/// output the keys pass through to macOS untouched. Intercepting them needs Accessibility permission.
@MainActor
final class MediaKeys {
    enum Key { case up, down, mute }

    private(set) var isInstalled = false

    /// Decides per key press whether to take it, and handles it if so.
    private let shouldHandle: () -> Bool
    private let onKey: (Key, _ fine: Bool) -> Void
    private let onInstall: () -> Void
    private var tap: CFMachPort?
    private var retryTimer: Timer?

    // NX_KEYTYPE_* from IOKit's ev_keymap.h; subtype 8 is NX_SUBTYPE_AUX_CONTROL_BUTTONS.
    private static let soundUp = 0, soundDown = 1, mute = 7
    private static let auxControlButtons: Int16 = 8

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    init(shouldHandle: @escaping () -> Bool, onKey: @escaping (Key, Bool) -> Void, onInstall: @escaping () -> Void) {
        self.shouldHandle = shouldHandle
        self.onKey = onKey
        self.onInstall = onInstall
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt.
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Installs the event tap now if permitted, otherwise keeps checking until permission is granted.
    func start() {
        install()
        guard !isInstalled, retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.install()
                if self.isInstalled {
                    timer.invalidate()
                    self.retryTimer = nil
                }
            }
        }
    }

    private func install() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1) << CGEventMask(NSEvent.EventType.systemDefined.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let keys = Unmanaged<MediaKeys>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated { keys.handle(type, event) }
            },
            userInfo: refcon)
        else {
            audioLog.error("Couldn't create the volume-key event tap")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isInstalled = true
        onInstall()
    }

    /// Runs on the main run loop. Returning nil swallows the key so macOS doesn't show its "can't change volume" HUD.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == Self.auxControlButtons else {
            return Unmanaged.passUnretained(event)
        }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let key: Key
        switch code {
        case Self.soundUp: key = .up
        case Self.soundDown: key = .down
        case Self.mute: key = .mute
        default: return Unmanaged.passUnretained(event)
        }
        guard shouldHandle() else { return Unmanaged.passUnretained(event) }

        let isDown = (ns.data1 & 0xFF00) >> 8 == 0xA
        let isRepeat = ns.data1 & 0x1 != 0
        if isDown && !(key == .mute && isRepeat) {
            // ⇧⌥ + volume = quarter steps, as in macOS.
            onKey(key, ns.modifierFlags.contains([.shift, .option]))
        }
        return nil
    }
}
