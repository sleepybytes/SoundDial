import AppKit
import CoreAudio
import Observation

/// One user-facing app and all the audio process objects that belong to it
/// (e.g. Chrome plus its helper processes).
struct AudioApp: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let pid: pid_t
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
    var isRecording: Bool
}

private typealias ResponsiblePIDFn = @convention(c) (pid_t) -> pid_t

/// `responsibility_get_pid_responsible_for_pid` maps helper processes (Chrome Helper,
/// WebKit WebContent for Safari, …) to the app that launched them.
private let responsiblePID: ResponsiblePIDFn? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(symbol, to: ResponsiblePIDFn.self)
}()

@Observable @MainActor
final class ProcessMonitor {
    private(set) var apps: [AudioApp] = []

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var listener: PropertyListener?
    @ObservationIgnored private var timer: Timer?

    init() {
        refresh()
        listener = PropertyListener(CA.system, .init(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            self?.refresh()
        }
        // Playing/recording state changes aren't covered by the list listener; poll them cheaply.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func app(_ bundleID: String?) -> AudioApp? {
        bundleID.flatMap { id in apps.first { $0.bundleID == id } }
    }

    func refresh() {
        let objects = (try? CA.getArray(CA.system, .init(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)) ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
        var grouped: [String: AudioApp] = [:]

        for object in objects {
            guard let pid = try? CA.get(object, .init(kAudioProcessPropertyPID), initial: pid_t(0)), pid > 0, pid != ownPID else { continue }
            let processBundle = (try? CA.getString(object, .init(kAudioProcessPropertyBundleID))) ?? ""
            guard let owner = Self.owner(pid: pid, processBundle: processBundle, running: running),
                  owner.processIdentifier != ownPID,
                  let bundleID = owner.bundleIdentifier else { continue }
            let playing = ((try? CA.get(object, .init(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0))) ?? 0) != 0
            let recording = ((try? CA.get(object, .init(kAudioProcessPropertyIsRunningInput), initial: UInt32(0))) ?? 0) != 0

            var app = grouped[bundleID] ?? AudioApp(
                bundleID: bundleID,
                name: owner.localizedName ?? bundleID,
                pid: owner.processIdentifier,
                processObjects: [],
                isPlaying: false,
                isRecording: false)
            app.processObjects.append(object)
            app.isPlaying = app.isPlaying || playing
            app.isRecording = app.isRecording || recording
            grouped[bundleID] = app
        }

        let result = grouped.values
            .map { var a = $0; a.processObjects.sort(); return a }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if result != apps {
            apps = result
            onChange?()
        }
    }

    private static func owner(pid: pid_t, processBundle: String, running: [NSRunningApplication]) -> NSRunningApplication? {
        if let rpid = responsiblePID?(pid), rpid > 0, let app = NSRunningApplication(processIdentifier: rpid), app.bundleIdentifier != nil {
            return app
        }
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil {
            return app
        }
        // Fall back to bundle-ID prefix: "com.google.Chrome.helper" → "com.google.Chrome".
        guard !processBundle.isEmpty else { return nil }
        return running
            .filter { app in app.bundleIdentifier.map { processBundle.hasPrefix($0 + ".") } ?? false }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }
}

/// Cached app icons by bundle ID.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ bundleID: String) -> NSImage {
        if let icon = cache[bundleID] { return icon }
        let icon: NSImage
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon {
            icon = running
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleID] = icon
        return icon
    }
}
