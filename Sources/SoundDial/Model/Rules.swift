import Foundation
import Observation

/// What the user wants for one app. Devices are stored by UID so rules survive replugging.
struct AppRule: Codable, Hashable {
    var bundleID: String
    var name: String
    /// nil = follow the system default output.
    var outputUID: String?
    var volume: Float = 1
    var muted = false
    /// When this app starts using the mic, switch the system default input to this device.
    var inputUID: String?

    var gain: Float { muted ? 0 : volume }
}

@Observable @MainActor
final class RuleStore {
    private(set) var rules: [String: AppRule] {
        didSet { save() }
    }

    /// Device UIDs for hotkey slots 1, 2, 3.
    var slots: [String?] {
        didSet { UserDefaults.standard.set(slots.map { $0 ?? "" }, forKey: "slots") }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "rules"),
           let decoded = try? JSONDecoder().decode([String: AppRule].self, from: data) {
            rules = decoded
        } else {
            rules = [:]
        }
        let stored = UserDefaults.standard.stringArray(forKey: "slots") ?? []
        slots = (0..<3).map { i in i < stored.count && !stored[i].isEmpty ? stored[i] : nil }
    }

    func rule(_ bundleID: String) -> AppRule? { rules[bundleID] }

    func update(_ bundleID: String, name: String, _ change: (inout AppRule) -> Void) {
        var rule = rules[bundleID] ?? AppRule(bundleID: bundleID, name: name)
        change(&rule)
        rules[bundleID] = rule
    }

    func remove(_ bundleID: String) {
        rules[bundleID] = nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: "rules")
        }
    }
}
