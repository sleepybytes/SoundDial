import AudioToolbox
import CoreAudio
import Foundation
import Observation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let hasOutput: Bool
    let hasInput: Bool

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return hasOutput ? "laptopcomputer" : "mic"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
        case kAudioDeviceTransportTypeUSB: return hasOutput ? "headphones" : "mic"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "iphone"
        default: return hasOutput ? "hifispeaker" : "mic"
        }
    }
}

/// Lists input/output devices, tracks the system defaults and owns device volume
/// (hardware where the device supports it, a software gain otherwise — e.g. DisplayPort monitors).
@Observable @MainActor
final class DeviceManager {
    private(set) var outputs: [AudioDevice] = []
    private(set) var inputs: [AudioDevice] = []
    private(set) var defaultOutputUID: String?
    private(set) var defaultInputUID: String?
    /// Last known volume per output device UID (hardware or software).
    private(set) var volumes: [String: Float] = [:]
    private(set) var softGains: [String: Float] {
        didSet { UserDefaults.standard.set(softGains, forKey: "softGains") }
    }
    /// Whether macOS could start each output the last time it was checked. A monitor whose audio
    /// link is down fails here; apps routed to it fall back to the default output until it passes.
    private(set) var availability: [String: Bool] = [:]

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var listeners: [PropertyListener] = []
    @ObservationIgnored private var volumeListeners: [PropertyListener] = []
    @ObservationIgnored private var reprobeTimer: Timer?
    /// Starting a broken device can block for ~10 s, so checks run here, never on the main thread.
    @ObservationIgnored private let probeQueue = DispatchQueue(label: "com.amit.SoundDial.probe", qos: .utility)
    @ObservationIgnored private var probing: Set<String> = []
    /// Device object each availability result was measured on; a replugged device gets a new one.
    @ObservationIgnored private var probedIDs: [String: AudioObjectID] = [:]

    private static let volumeAddress = AudioObjectPropertyAddress(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)

    init() {
        softGains = (UserDefaults.standard.dictionary(forKey: "softGains") as? [String: Float]) ?? [:]
        refresh()
        reprobe()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            listeners.append(PropertyListener(CA.system, .init(selector)) { [weak self] in
                self?.refresh()
                self?.reprobe()
                self?.onChange?()
            })
        }
        reprobeTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reprobe() }
        }
    }

    func refresh() {
        let ids = (try? CA.getArray(CA.system, .init(kAudioHardwarePropertyDevices), of: AudioObjectID.self)) ?? []
        var outs: [AudioDevice] = []
        var ins: [AudioDevice] = []
        for id in ids {
            guard let device = Self.describe(id) else { continue }
            if device.hasOutput { outs.append(device) }
            if device.hasInput { ins.append(device) }
        }
        if outs != outputs { outputs = outs }
        if ins != inputs { inputs = ins }
        let outUID = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice).flatMap { Self.uid(of: $0) }
        let inUID = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap { Self.uid(of: $0) }
        if outUID != defaultOutputUID { defaultOutputUID = outUID }
        if inUID != defaultInputUID { defaultInputUID = inUID }
        refreshVolumes()

        volumeListeners = outs.filter { hasHardwareVolume($0.uid) }.map { device in
            PropertyListener(device.id, Self.volumeAddress) { [weak self] in self?.refreshVolumes() }
        }
    }

    private func refreshVolumes() {
        var v: [String: Float] = [:]
        for device in outputs {
            v[device.uid] = hasHardwareVolume(device.uid)
                ? (try? CA.get(device.id, Self.volumeAddress, initial: Float32(0))) ?? 0
                : softGains[device.uid] ?? 1
        }
        if v != volumes { volumes = v }
    }

    // MARK: Lookup

    func output(uid: String?) -> AudioDevice? { uid.flatMap { u in outputs.first { $0.uid == u } } }
    func input(uid: String?) -> AudioDevice? { uid.flatMap { u in inputs.first { $0.uid == u } } }
    var defaultOutput: AudioDevice? { output(uid: defaultOutputUID) }

    /// The device an app with this preferred output actually plays on: its own device when connected
    /// and able to play, otherwise the system default.
    func effectiveOutput(preferredUID: String?) -> AudioDevice? {
        if let device = output(uid: preferredUID), !isUnavailable(device.uid) { return device }
        return defaultOutput
    }

    // MARK: Availability

    func isUnavailable(_ uid: String?) -> Bool {
        uid.flatMap { availability[$0] } == false
    }

    /// True once the output has been checked and can play. Unchecked outputs get a check started.
    func isReady(_ uid: String) -> Bool {
        if availability[uid] == true { return true }
        if availability[uid] == nil { probe(uid) }
        return false
    }

    var unavailableUIDs: Set<String> {
        Set(availability.filter { !$0.value }.keys)
    }

    /// Checks in the background whether macOS can start this output; calls `onChange` if the answer changed.
    func probe(_ uid: String) {
        guard let device = output(uid: uid), !probing.contains(uid) else { return }
        probing.insert(uid)
        let id = device.id
        probeQueue.async { [weak self] in
            let status = DeviceManager.startStatus(id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishProbe(uid: uid, id: id, name: device.name, status: status) }
            }
        }
    }

    private func finishProbe(uid: String, id: AudioObjectID, name: String, status: OSStatus) {
        probing.remove(uid)
        guard output(uid: uid)?.id == id else { return } // unplugged or replugged meanwhile
        let ok = status == noErr
        let old = availability[uid]
        probedIDs[uid] = id
        guard old != ok else { return }
        availability[uid] = ok
        if !ok {
            audioLog.error("\(name, privacy: .public) can't start audio: \(status) '\(fourCC(status), privacy: .public)'")
        } else if old == false {
            audioLog.info("\(name, privacy: .public) can play audio again")
        }
        onChange?()
    }

    /// Forgets results for unplugged or replugged devices, re-checks failed ones and the default output.
    private func reprobe() {
        for uid in availability.keys where output(uid: uid)?.id != probedIDs[uid] {
            availability[uid] = nil
            probedIDs[uid] = nil
        }
        for (uid, ok) in availability where !ok { probe(uid) }
        if let uid = defaultOutputUID, availability[uid] == nil { probe(uid) }
    }

    /// Starts and stops a silent IO proc. Blocks for up to ~10 s on a broken device.
    nonisolated private static func startStatus(_ id: AudioObjectID) -> OSStatus {
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, id, nil) { _, _, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
        guard status == noErr, let procID else { return status }
        status = AudioDeviceStart(id, procID)
        AudioDeviceStop(id, procID)
        AudioDeviceDestroyIOProcID(id, procID)
        return status
    }

    // MARK: Defaults

    func setDefaultOutput(_ uid: String) {
        guard let device = output(uid: uid) else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            do { try CA.set(CA.system, .init(selector), device.id) } catch { audioLog.error("\(error.localizedDescription)") }
        }
        refresh()
        if availability[uid] != true { probe(uid) }
    }

    func setDefaultInput(_ uid: String) {
        guard let device = input(uid: uid) else { return }
        do { try CA.set(CA.system, .init(kAudioHardwarePropertyDefaultInputDevice), device.id) } catch {
            audioLog.error("\(error.localizedDescription)")
        }
        refresh()
    }

    // MARK: Volume

    func hasHardwareVolume(_ uid: String) -> Bool {
        guard let device = output(uid: uid) else { return false }
        return CA.isSettable(device.id, Self.volumeAddress)
    }

    func volume(_ uid: String) -> Float { volumes[uid] ?? 1 }

    /// Gain SoundDial must apply itself for apps playing on this device (1 when the device has hardware volume).
    func softGain(_ uid: String) -> Float {
        hasHardwareVolume(uid) ? 1 : softGains[uid] ?? 1
    }

    func setVolume(_ uid: String, _ value: Float) {
        let v = min(max(value, 0), 1)
        if hasHardwareVolume(uid), let device = output(uid: uid) {
            try? CA.set(device.id, Self.volumeAddress, Float32(v))
        } else {
            softGains[uid] = v
            onChange?()
        }
        refreshVolumes()
    }

    // MARK: Helpers

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        let id = try? CA.get(CA.system, .init(selector), initial: AudioObjectID(kAudioObjectUnknown))
        return id == AudioObjectID(kAudioObjectUnknown) ? nil : id
    }

    private static func uid(of id: AudioObjectID) -> String? {
        try? CA.getString(id, .init(kAudioDevicePropertyDeviceUID))
    }

    private static func describe(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = uid(of: id), let name = try? CA.getString(id, .init(kAudioObjectPropertyName)) else { return nil }
        let transport = (try? CA.get(id, .init(kAudioDevicePropertyTransportType), initial: UInt32(0))) ?? 0
        // Skip aggregate devices, including the private ones SoundDial creates.
        if transport == kAudioDeviceTransportTypeAggregate || uid.hasPrefix("com.amit.SoundDial") { return nil }
        let outStreams = (try? CA.getArray(id, .init(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), of: AudioStreamID.self)) ?? []
        let inStreams = (try? CA.getArray(id, .init(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput), of: AudioStreamID.self)) ?? []
        guard !outStreams.isEmpty || !inStreams.isEmpty else { return nil }
        return AudioDevice(id: id, uid: uid, name: name, transport: transport, hasOutput: !outStreams.isEmpty, hasInput: !inStreams.isEmpty)
    }
}
