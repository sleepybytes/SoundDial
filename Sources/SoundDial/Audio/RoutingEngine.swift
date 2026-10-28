import CoreAudio
import Foundation

/// Turns rules + running apps + devices into the set of live `AppTap`s.
/// Apps that need nothing (default device, 100%, device has hardware volume) are left untapped.
@MainActor
final class RoutingEngine {
    private(set) var taps: [String: AppTap] = [:]
    private var lastPlayed: [String: Date] = [:]
    private var failures: [String: (key: String, at: Date)] = [:]

    /// How long an app stays tapped after it stops playing when the only reason to tap it
    /// is a software-volume device (e.g. the DisplayPort monitor).
    private let idleGrace: TimeInterval = 30

    func reconcile(apps: [AudioApp], rules: RuleStore, devices: DeviceManager, enabled: Bool) {
        guard enabled else {
            teardown()
            return
        }
        let now = Date()
        var desired: [String: (objects: [AudioObjectID], output: AudioDevice, gain: Float)] = [:]

        for app in apps where !app.processObjects.isEmpty {
            if app.isPlaying { lastPlayed[app.bundleID] = now }
            let rule = rules.rule(app.bundleID)
            guard let output = devices.effectiveOutput(preferredUID: rule?.outputUID) else { continue }
            let appGain = rule?.gain ?? 1
            let deviceGain = devices.softGain(output.uid)
            let rerouted = output.uid != devices.defaultOutputUID
            let recentlyPlayed = lastPlayed[app.bundleID].map { now.timeIntervalSince($0) < idleGrace } ?? false

            if rerouted || appGain != 1 || (deviceGain != 1 && recentlyPlayed) {
                desired[app.bundleID] = (app.processObjects, output, appGain * deviceGain)
            }
        }

        for (bundleID, tap) in taps {
            if let want = desired[bundleID], want.objects == tap.processObjects, want.output == tap.output {
                tap.gain = want.gain
            } else {
                tap.stop()
                taps[bundleID] = nil
            }
        }

        for (bundleID, want) in desired where taps[bundleID] == nil {
            // Starting a tap on an output that can't play blocks for seconds, so wait until it's checked;
            // the check's result triggers another reconcile.
            guard devices.isReady(want.output.uid) else { continue }
            let key = "\(want.objects)|\(want.output.id)"
            if let failure = failures[bundleID], failure.key == key, now.timeIntervalSince(failure.at) < 10 { continue }
            do {
                taps[bundleID] = try AppTap(bundleID: bundleID, processObjects: want.objects, output: want.output, gain: want.gain)
                failures[bundleID] = nil
                audioLog.info("Tapped \(bundleID, privacy: .public) → \(want.output.name, privacy: .public) gain \(want.gain)")
            } catch {
                failures[bundleID] = (key, now)
                audioLog.error("Tap \(bundleID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                devices.probe(want.output.uid)
            }
        }
    }

    func teardown() {
        for tap in taps.values { tap.stop() }
        taps.removeAll()
    }
}
