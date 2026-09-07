import CoreAudio
import Foundation

/// A failed HAL property call, carrying the raw `OSStatus` and the property that failed.
struct AudioObjectError: Error, CustomStringConvertible, Hashable {
    let status: OSStatus
    let selector: AudioObjectPropertySelector
    let objectID: AudioObjectID

    /// The status as a four-char code when it is printable, otherwise its decimal form.
    var statusCode: String { fourCharCode(UInt32(bitPattern: status)) }
    var selectorCode: String { fourCharCode(selector) }

    var description: String {
        "AudioObject \(objectID): property '\(selectorCode)' failed with \(statusCode)"
    }
}

/// Renders an `OSType` as its four ASCII characters, or as a decimal number when any byte is not printable.
func fourCharCode(_ value: UInt32) -> String {
    let bytes = [value >> 24, value >> 16, value >> 8, value].map { UInt8($0 & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return String(Int32(bitPattern: value)) }
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

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    func has(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(self, &address)
    }

    func isSettable(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(self, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    func dataSize(_ address: AudioObjectPropertyAddress) throws -> UInt32 {
        var address = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), address)
        return size
    }

    /// Reads a property whose value is one fixed-size struct or scalar.
    func value<T>(_ address: AudioObjectPropertyAddress, qualifier: CFString? = nil) throws -> T {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        try withQualifier(qualifier) { qualifierSize, qualifierData in
            try check(
                AudioObjectGetPropertyData(self, &address, qualifierSize, qualifierData, &size, buffer),
                address)
        }
        return buffer.assumingMemoryBound(to: T.self).pointee
    }

    func setValue<T>(_ address: AudioObjectPropertyAddress, _ newValue: T) throws {
        var address = address
        var newValue = newValue
        try withUnsafeBytes(of: &newValue) { raw in
            try check(
                AudioObjectSetPropertyData(
                    self, &address, 0, nil, UInt32(raw.count), raw.baseAddress!),
                address)
        }
    }

    func string(_ address: AudioObjectPropertyAddress) throws -> String {
        var address = address
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer), address)
        }
        return value as String? ?? ""
    }

    /// Reads a property whose value is a variable-length array of a trivial element type.
    func array<T>(_ address: AudioObjectPropertyAddress) throws -> [T] {
        var address = address
        var size = try dataSize(address)
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        try check(
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!), address)
        return Array(buffer.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// Reads an `AudioBufferList`-shaped property, such as a stream configuration, and hands the
    /// buffers to `body`. The pointer is valid only for the duration of the call.
    func bufferList<R>(
        _ address: AudioObjectPropertyAddress,
        _ body: (UnsafeMutableAudioBufferListPointer) throws -> R
    ) throws -> R {
        var address = address
        var size = try dataSize(address)
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw), address)
        return try body(UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)))
    }

    func check(_ status: OSStatus, _ address: AudioObjectPropertyAddress) throws {
        guard status != noErr else { return }
        throw AudioObjectError(status: status, selector: address.mSelector, objectID: self)
    }

    private func withQualifier<R>(
        _ qualifier: CFString?, _ body: (UInt32, UnsafeRawPointer?) throws -> R
    ) rethrows -> R {
        guard var qualifier else { return try body(0, nil) }
        return try withUnsafePointer(to: &qualifier) {
            try body(UInt32(MemoryLayout<CFString>.size), UnsafeRawPointer($0))
        }
    }
}

/// A live property listener. The listener is removed when this object is released, so keep it
/// alive for as long as the notifications are wanted.
final class AudioObjectPropertyListener: @unchecked Sendable {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    /// Registers `handler`, which runs on the main queue with the addresses that changed.
    @MainActor
    init(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        handler: @escaping @MainActor ([AudioObjectPropertyAddress]) -> Void
    ) throws {
        self.objectID = objectID
        self.address = address
        self.block = { count, addresses in
            let changed = (0..<Int(count)).map { addresses[$0] }
            MainActor.assumeIsolated { handler(changed) }
        }
        try objectID.check(
            AudioObjectAddPropertyListenerBlock(objectID, &self.address, DispatchQueue.main, block),
            address)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
    }
}
