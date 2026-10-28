import Foundation

/// macOS can't give each app its own mic without a virtual driver, so instead: when an app with an
/// input rule starts recording, make its device the system default input; restore the previous
/// default when no ruled app is recording. The most recent app to start recording wins.
@MainActor
final class InputSwitcher {
    private var recordingOrder: [String] = []
    private var savedDefaultUID: String?
    private var appliedUID: String?

    func update(apps: [AudioApp], rules: RuleStore, devices: DeviceManager) {
        let recording = apps
            .filter { $0.isRecording && devices.input(uid: rules.rule($0.bundleID)?.inputUID) != nil }
            .map(\.bundleID)
        recordingOrder.removeAll { !recording.contains($0) }
        for bundleID in recording where !recordingOrder.contains(bundleID) {
            recordingOrder.append(bundleID)
        }

        if let top = recordingOrder.last, let uid = rules.rule(top)?.inputUID {
            if appliedUID == nil { savedDefaultUID = devices.defaultInputUID }
            if devices.defaultInputUID != uid { devices.setDefaultInput(uid) }
            appliedUID = uid
        } else if let applied = appliedUID {
            // Only restore if the user didn't pick another input in the meantime.
            if devices.defaultInputUID == applied, let saved = savedDefaultUID, devices.input(uid: saved) != nil {
                devices.setDefaultInput(saved)
            }
            appliedUID = nil
            savedDefaultUID = nil
        }
    }
}
