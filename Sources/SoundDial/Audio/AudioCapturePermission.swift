import Foundation

/// "System Audio Recording" (kTCCServiceAudioCapture) permission, needed for process taps.
/// There's no public API to check it, so this uses TCC's preflight/request functions.
/// Without the permission a tap delivers silence while still muting the app, so the
/// routing engine stays off until access is granted.
enum AudioCapturePermission {
    enum Status { case authorized, denied, undetermined }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .authorized }
        switch unsafeBitCast(symbol, to: PreflightFn.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    static func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else {
            Task { @MainActor in completion(true) }
            return
        }
        unsafeBitCast(symbol, to: RequestFn.self)(service, nil) { granted in
            Task { @MainActor in completion(granted) }
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
