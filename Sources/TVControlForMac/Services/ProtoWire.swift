// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// The Android TV Remote protocol is protobuf over TLS. It needs a dozen tiny messages, so
// rather than pull in a protobuf toolchain these types speak the wire format directly:
// a varint tag (field number << 3 | wire type) followed by a varint or a length-prefixed blob.

/// A protobuf or framing input that can't be what the TV meant to send.
struct ProtoError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Builds one protobuf message field by field.
struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    @discardableResult
    mutating func varint(_ field: Int, _ value: UInt64) -> ProtoWriter {
        writeRaw(UInt64(field) << 3)
        writeRaw(value)
        return self
    }

    @discardableResult
    mutating func bytes(_ field: Int, _ value: [UInt8]) -> ProtoWriter {
        writeRaw(UInt64(field) << 3 | 2)
        writeRaw(UInt64(value.count))
        bytes.append(contentsOf: value)
        return self
    }

    @discardableResult
    mutating func string(_ field: Int, _ value: String) -> ProtoWriter {
        bytes(field, Array(value.utf8))
    }

    @discardableResult
    mutating func message(_ field: Int, _ inner: ProtoWriter) -> ProtoWriter {
        bytes(field, inner.bytes)
    }

    // Chainable forms, so a nested message reads like its definition.
    func withVarint(_ field: Int, _ value: UInt64) -> ProtoWriter { var w = self; w.varint(field, value); return w }
    func withBytes(_ field: Int, _ value: [UInt8]) -> ProtoWriter { var w = self; w.bytes(field, value); return w }
    func withString(_ field: Int, _ value: String) -> ProtoWriter { var w = self; w.string(field, value); return w }
    func withMessage(_ field: Int, _ inner: ProtoWriter) -> ProtoWriter { var w = self; w.message(field, inner); return w }

    private mutating func writeRaw(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }
}

/// A parsed protobuf message: just enough to look fields up by number.
struct ProtoMessage {
    private struct Field {
        let number: Int
        let varint: UInt64
        let bytes: [UInt8]?
    }

    private var fields: [Field] = []

    /// Parses a message. Throws `ProtoError` on malformed input, never traps.
    static func parse(_ data: [UInt8]) throws -> ProtoMessage {
        var msg = ProtoMessage()
        var pos = 0
        while pos < data.count {
            let tag = try readVarint(data, &pos)
            // Field numbers are at most 2^29 - 1; anything larger is garbage, not a field.
            guard tag >> 3 <= UInt64(Int32.max) else { throw ProtoError("Protobuf field number out of range.") }
            let field = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                msg.fields.append(Field(number: field, varint: try readVarint(data, &pos), bytes: nil))
            case 1:
                pos = try skip(data, pos, 8)
            case 2:
                let length = try readVarint(data, &pos)
                guard length <= UInt64(data.count - pos) else { throw ProtoError("Truncated protobuf field.") }
                let end = pos + Int(length)
                msg.fields.append(Field(number: field, varint: 0, bytes: Array(data[pos..<end])))
                pos = end
            case 5:
                pos = try skip(data, pos, 4)
            default:
                throw ProtoError("Unsupported protobuf wire type.")
            }
        }
        return msg
    }

    func has(_ field: Int) -> Bool { fields.contains { $0.number == field } }

    /// The varint value of a field, or nil when it's absent (proto3 omits zero/false).
    func varint(_ field: Int) -> UInt64? {
        fields.first { $0.number == field && $0.bytes == nil }?.varint
    }

    /// The nested message in a field, or nil when it's absent or not parseable as one.
    func message(_ field: Int) -> ProtoMessage? {
        guard let bytes = fields.first(where: { $0.number == field && $0.bytes != nil })?.bytes else { return nil }
        return try? ProtoMessage.parse(bytes)
    }

    func string(_ field: Int) -> String? {
        bytes(field).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The raw contents of a length-delimited field, or nil when it's absent.
    func bytes(_ field: Int) -> [UInt8]? {
        fields.first { $0.number == field && $0.bytes != nil }?.bytes
    }

    private static func skip(_ data: [UInt8], _ pos: Int, _ count: Int) throws -> Int {
        guard count <= data.count - pos else { throw ProtoError("Truncated protobuf field.") }
        return pos + count
    }

    private static func readVarint(_ data: [UInt8], _ pos: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 {
            guard pos < data.count else { throw ProtoError("Truncated protobuf varint.") }
            let b = data[pos]
            pos += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtoError("Protobuf varint too long.")
    }
}

/// Length-delimited framing: each message on the stream is preceded by its varint length.
enum ProtoFraming {
    /// No message in this protocol comes close; a bigger length means a corrupt stream, and
    /// trusting it would have us allocate whatever the peer claims.
    static let maxMessageBytes = 1 << 20

    /// Prefix and body as one buffer, so a frame goes out in a single send and is never
    /// split around another writer's frame.
    static func frame(_ message: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(message.count + 5)
        var length = UInt32(message.count)
        while length >= 0x80 {
            out.append(UInt8(truncatingIfNeeded: length) | 0x80)
            length >>= 7
        }
        out.append(UInt8(length))
        out.append(contentsOf: message)
        return out
    }

    /// Reads one frame using `nextByte`/`nextBytes`, which pull from the stream (and throw
    /// when it ends). Throws `ProtoError` for a length that's malformed or over the cap.
    static func read(nextByte: () async throws -> UInt8,
                     nextBytes: (Int) async throws -> [UInt8]) async throws -> [UInt8] {
        var length = 0
        var shift = 0
        while true {
            if shift > 28 { throw ProtoError("Frame length varint too long.") }
            let b = try await nextByte()
            length |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        guard length >= 0, length <= maxMessageBytes else { throw ProtoError("Frame too large.") }
        return length == 0 ? [] : try await nextBytes(length)
    }
}
