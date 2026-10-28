import AudioToolbox
import CoreAudio
import Foundation
import os

let audioLog = Logger(subsystem: "com.amit.SoundDial", category: "audio")

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String

    init(_ status: OSStatus, _ operation: String) {
        self.status = status
        self.operation = operation
    }

    var description: String { "\(operation) failed: \(status) '\(fourCC(status))'" }
}

func fourCC(_ value: OSStatus) -> String {
    let n = UInt32(bitPattern: value)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return String(value) }
    return String(decoding: bytes, as: UTF8.self)
}

extension AudioObjectPropertyAddress {
    init(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

/// Thin typed wrappers around the AudioObject property C API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        return AudioObjectHasProperty(object, &addr)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &addr) else { return false }
        return AudioObjectIsPropertySettable(object, &addr, &settable) == noErr && settable.boolValue
    }

    static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) throws -> T {
        var addr = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { throw CoreAudioError(status, "get '\(fourCC(OSStatus(bitPattern: address.mSelector)))'") }
        return value
    }

    static func getString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        var addr = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else {
            throw CoreAudioError(status, "get string '\(fourCC(OSStatus(bitPattern: address.mSelector)))'")
        }
        return value.takeRetainedValue() as String
    }

    static func getArray<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of _: T.Type) throws -> [T] {
        var addr = address
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(status, "get size '\(fourCC(OSStatus(bitPattern: address.mSelector)))'") }
        let capacity = Int(size) / MemoryLayout<T>.stride
        guard capacity > 0 else { return [] }
        let result = [T](unsafeUninitializedCapacity: capacity) { buffer, initialized in
            status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer.baseAddress!)
            initialized = status == noErr ? min(capacity, Int(size) / MemoryLayout<T>.stride) : 0
        }
        guard status == noErr else { throw CoreAudioError(status, "get array '\(fourCC(OSStatus(bitPattern: address.mSelector)))'") }
        return result
    }

    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var addr = address
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        guard status == noErr else { throw CoreAudioError(status, "set '\(fourCC(OSStatus(bitPattern: address.mSelector)))'") }
    }
}

/// Registers a Core Audio property listener for as long as the object is alive.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, queue: DispatchQueue = .main, handler: @escaping () -> Void) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block)
        if status != noErr {
            audioLog.error("Add listener '\(fourCC(OSStatus(bitPattern: address.mSelector)))' failed: \(status)")
        }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
