// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Network
import Security

// A minimal ADB (Android Debug Bridge) client over TCP: just enough to authenticate and run
// one shell command at a time. It exists so the app can reach settings that the Android TV
// Remote protocol has no channel for (picture brightness) without shipping the adb binary.
//
// Wire format: every message is a 24-byte little-endian header
//   command, arg0, arg1, payload length, payload checksum (byte sum), command ^ 0xFFFFFFFF
// followed by the payload. A session goes
//   → CNXN                      ← AUTH(token)
//   → AUTH(signature of token)  ← CNXN            (key already trusted)
//                           or  ← AUTH(token) again, then
//   → AUTH(public key)          ← CNXN            (after "Allow USB debugging?" is accepted)
// and each shell command is its own stream: OPEN "shell:<cmd>" → OKAY, WRTE…, CLSE.
//
// Every wait is bounded by a deadline the caller passes in. When one runs out, or the task
// is cancelled, the connection is torn down rather than left in an unknown state halfway
// through a message: the next use reconnects.

/// The TV turned the connection down in a way retrying won't fix.
struct AdbRejection: LocalizedError {
    let message: String
    /// True when the TV doesn't know our key and we were told not to ask for approval.
    let needsApproval: Bool

    init(_ message: String, needsApproval: Bool = false) {
        self.message = message
        self.needsApproval = needsApproval
    }

    var errorDescription: String? { message }
}

/// The connection itself failed: unreachable, dropped, too slow, or garbled. Retrying can help.
enum AdbConnectionError: LocalizedError {
    case connectFailed(String)
    case connectionLost(String)
    case closed
    case timedOut
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .connectFailed(let why): "Can't reach ADB: \(why)"
        case .connectionLost(let why): "ADB connection lost: \(why)"
        case .closed: "Not connected."
        case .timedOut: "The TV didn't answer in time."
        case .malformed(let what): "Malformed ADB message: \(what)"
        }
    }
}

final class AdbClient: @unchecked Sendable {
    static let defaultPort: UInt16 = 5555

    static let cmdConnect: UInt32 = 0x4e58_4e43 // CNXN
    static let cmdAuth: UInt32 = 0x4854_5541    // AUTH
    static let cmdOpen: UInt32 = 0x4e45_504f    // OPEN
    static let cmdOkay: UInt32 = 0x5941_4b4f    // OKAY
    static let cmdClose: UInt32 = 0x4553_4c43   // CLSE
    static let cmdWrite: UInt32 = 0x4554_5257   // WRTE
    static let cmdStartTls: UInt32 = 0x534c_5453 // STLS

    private static let authToken: UInt32 = 1
    private static let authSignature: UInt32 = 2
    private static let authPublicKey: UInt32 = 3

    // The original protocol version: small payloads, checksums on. Every adbd accepts it.
    static let protocolVersion: UInt32 = 0x0100_0000
    static let maxPayload: UInt32 = 4096
    static let maxIncomingPayload: UInt32 = 1 << 20
    /// Cap on what one shell command may print, so a runaway command can't eat memory.
    private static let maxShellOutput = 1 << 20

    private static let connectTimeout: TimeInterval = 4
    private static let handshakeTimeout: TimeInterval = 6

    private let queue = DispatchQueue(label: "TVControlForMac.AdbClient")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var ready = false
    private var disposed = false

    // Bytes received but not consumed yet. Only ever touched by the one reader there is at a
    // time: the handshake, then shell commands one after another under `commandLock`.
    private var buffer: [UInt8] = []
    private let commandLock = AdbLock()
    private var nextLocalId: UInt32 = 0

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return connection != nil && ready && !disposed
    }

    /// Creates the RSA key that identifies this app to a TV, as base64 PKCS#8.
    static func createKey() throws -> String {
        try AdbKey.create()
    }

    /// Connects and authenticates with `keyBase64` (from `createKey`). If the TV doesn't know
    /// the key yet it asks the person in front of it to allow debugging; `onApprovalNeeded`
    /// fires at that point and the call then waits up to `approvalTimeout` for the answer.
    /// Pass 0 to never put that dialog on the TV: an unknown key then fails with an
    /// `AdbRejection` whose `needsApproval` is set.
    ///
    /// On any failure the connection is closed before the error is thrown.
    func connect(host: String, port: UInt16 = AdbClient.defaultPort, keyBase64: String, keyName: String,
                 onApprovalNeeded: (() -> Void)?, approvalTimeout: TimeInterval) async throws {
        do {
            let key = try AdbKey.importPrivateKey(base64: keyBase64)
            try await open(host: host, port: port, deadline: .now() + Self.connectTimeout)

            var deadline = DispatchTime.now() + Self.handshakeTimeout
            try await send(Self.cmdConnect, Self.protocolVersion, Self.maxPayload,
                           Array("host::\0".utf8), until: deadline)

            var signatureTried = false
            while true {
                let message = try await receive(until: deadline)
                switch message.command {
                case Self.cmdConnect:
                    return

                case Self.cmdAuth where message.arg0 == Self.authToken && !signatureTried:
                    // The token stands in for a SHA-1 digest: sign it as one, PKCS#1 v1.5.
                    signatureTried = true
                    let signature = try AdbKey.sign(token: message.payload, with: key)
                    try await send(Self.cmdAuth, Self.authSignature, 0, signature, until: deadline)

                case Self.cmdAuth where message.arg0 == Self.authToken:
                    // Signature not recognised: offer the public key, which puts the
                    // "Allow USB debugging?" dialog on the TV. Give a human time to answer.
                    if approvalTimeout <= 0 {
                        throw AdbRejection("The TV hasn't approved this Mac for debugging.", needsApproval: true)
                    }
                    let line = try AdbKey.encodePublicKey(key) + " " + Self.asciiOnly(keyName) + "\0"
                    try await send(Self.cmdAuth, Self.authPublicKey, 0, Array(line.utf8), until: deadline)
                    onApprovalNeeded?()
                    deadline = .now() + approvalTimeout

                case Self.cmdStartTls:
                    throw AdbRejection("This TV only accepts encrypted ADB (wireless debugging), which isn't supported.")

                default:
                    throw AdbRejection("Unexpected reply while connecting to ADB.")
                }
            }
        } catch {
            dispose()
            throw error
        }
    }

    /// Runs one shell command on the TV and returns everything it printed. Waits for an
    /// earlier command to finish first; the whole exchange has to be over by `deadline`.
    func shell(_ command: String, until deadline: DispatchTime) async throws -> String {
        try await commandLock.acquire()
        defer { commandLock.release() }
        guard isConnected else { throw AdbConnectionError.closed }

        let request = Array(("shell:" + command + "\0").utf8)
        guard request.count <= Int(Self.maxPayload) else {
            throw AdbRejection("The command is too long for ADB.")
        }

        nextLocalId = nextLocalId == UInt32.max ? 1 : nextLocalId + 1
        let localId = nextLocalId
        try await send(Self.cmdOpen, localId, 0, request, until: deadline)

        var output: [UInt8] = []
        var remoteId: UInt32 = 0
        while true {
            let message = try await receive(until: deadline)
            if message.arg1 != localId { continue } // a leftover from an earlier, abandoned stream

            switch message.command {
            case Self.cmdOkay:
                remoteId = message.arg0
            case Self.cmdWrite:
                remoteId = message.arg0
                guard output.count + message.payload.count <= Self.maxShellOutput else {
                    throw AdbConnectionError.malformed("shell output too large")
                }
                output.append(contentsOf: message.payload)
                try await send(Self.cmdOkay, localId, remoteId, [], until: deadline)
            case Self.cmdClose:
                // arg0 == 0 here means the TV refused to open the stream at all.
                if message.arg0 != 0 {
                    try await send(Self.cmdClose, localId, message.arg0, [], until: deadline)
                } else if remoteId == 0 {
                    throw AdbRejection("The TV refused to run the command.")
                }
                return String(decoding: output, as: UTF8.self)
            default:
                break
            }
        }
    }

    /// Closes the connection. Anything waiting on it fails straight away. Safe to call
    /// from any thread, more than once.
    func dispose() {
        lock.lock()
        let connection = connection
        self.connection = nil
        ready = false
        disposed = true
        lock.unlock()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    // MARK: - Messages

    struct Header: Equatable {
        let command: UInt32
        let arg0: UInt32
        let arg1: UInt32
        let length: UInt32
        let checksum: UInt32
    }

    struct Message {
        let command: UInt32
        let arg0: UInt32
        let arg1: UInt32
        let payload: [UInt8]
    }

    /// One complete message as it goes on the wire.
    static func frame(_ command: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ payload: [UInt8]) -> [UInt8] {
        var message: [UInt8] = []
        message.reserveCapacity(24 + payload.count)
        for word in [command, arg0, arg1, UInt32(payload.count), checksum(payload), command ^ 0xFFFF_FFFF] {
            appendLE32(word, to: &message)
        }
        message.append(contentsOf: payload)
        return message
    }

    /// Reads a 24-byte header, refusing one whose magic doesn't match its command or whose
    /// payload is bigger than anything a TV has a reason to send.
    static func parseHeader(_ bytes: [UInt8]) throws -> Header {
        guard bytes.count == 24 else { throw AdbConnectionError.malformed("short header") }
        let header = Header(command: readLE32(bytes, 0), arg0: readLE32(bytes, 4), arg1: readLE32(bytes, 8),
                            length: readLE32(bytes, 12), checksum: readLE32(bytes, 16))
        guard header.command ^ 0xFFFF_FFFF == readLE32(bytes, 20) else {
            throw AdbConnectionError.malformed("bad magic")
        }
        guard header.length <= maxIncomingPayload else {
            throw AdbConnectionError.malformed("payload of \(header.length) bytes")
        }
        return header
    }

    static func checksum(_ payload: [UInt8]) -> UInt32 {
        payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
    }

    // Callers guarantee offset + 4 <= bytes.count.
    private static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    static func appendLE32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    // The key name ends up in a C string on the TV; keep it plain.
    private static func asciiOnly(_ text: String) -> String {
        String(text.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F ? Character($0) : "?" })
    }

    // MARK: - Transport

    private func currentConnection() throws -> NWConnection {
        lock.lock(); defer { lock.unlock() }
        guard let connection, !disposed else { throw AdbConnectionError.closed }
        return connection
    }

    private func setReady(_ value: Bool) {
        lock.lock(); ready = value; lock.unlock()
    }

    private func open(host: String, port: UInt16, deadline: DispatchTime) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw AdbConnectionError.connectFailed("bad port")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                      using: NWParameters(tls: nil, tcp: tcp))

        let usable = lock.withLock {
            let usable = !disposed && self.connection == nil
            if usable { self.connection = connection }
            return usable
        }
        guard usable else { throw AdbConnectionError.closed }

        try await bounded(until: deadline) { (done: @escaping (Result<Void, Error>) -> Void) in
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.setReady(true)
                    done(.success(()))
                case .waiting(let error):
                    // Refused or no route: say so now rather than sit out the timeout.
                    self?.setReady(false)
                    done(.failure(AdbConnectionError.connectFailed(error.localizedDescription)))
                case .failed(let error):
                    self?.setReady(false)
                    done(.failure(AdbConnectionError.connectFailed(error.localizedDescription)))
                case .cancelled:
                    self?.setReady(false)
                    done(.failure(AdbConnectionError.closed))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ command: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ payload: [UInt8],
                      until deadline: DispatchTime) async throws {
        let connection = try currentConnection()
        let message = Data(Self.frame(command, arg0, arg1, payload))
        try await bounded(until: deadline) { (done: @escaping (Result<Void, Error>) -> Void) in
            connection.send(content: message, completion: .contentProcessed { error in
                if let error {
                    done(.failure(AdbConnectionError.connectionLost(error.localizedDescription)))
                } else {
                    done(.success(()))
                }
            })
        }
    }

    private func receive(until deadline: DispatchTime) async throws -> Message {
        let header = try Self.parseHeader(try await readExactly(24, until: deadline))
        let payload = header.length > 0 ? try await readExactly(Int(header.length), until: deadline) : []
        return Message(command: header.command, arg0: header.arg0, arg1: header.arg1, payload: payload)
    }

    private func readExactly(_ count: Int, until deadline: DispatchTime) async throws -> [UInt8] {
        while buffer.count < count {
            let connection = try currentConnection()
            let chunk = try await bounded(until: deadline) { (done: @escaping (Result<Data, Error>) -> Void) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                    if let data, !data.isEmpty {
                        done(.success(data))
                    } else if let error {
                        done(.failure(AdbConnectionError.connectionLost(error.localizedDescription)))
                    } else {
                        // No data and no error: the TV closed its end.
                        done(.failure(AdbConnectionError.connectionLost("closed by the TV")))
                    }
                }
            }
            buffer.append(contentsOf: chunk)
        }
        let bytes = Array(buffer[0..<count])
        buffer.removeFirst(count)
        return bytes
    }

    /// Waits for a callback-style operation, but never past `deadline` and never past the
    /// task being cancelled. Either of those closes the connection: a read cut off halfway
    /// through a message leaves nothing usable behind.
    private func bounded<T>(until deadline: DispatchTime,
                            _ start: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let once = OnceFlag()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                    let finish: (Result<T, Error>) -> Void = { result in
                        if once.set() { continuation.resume(with: result) }
                    }
                    if Task.isCancelled {
                        finish(.failure(CancellationError()))
                        return
                    }
                    let timer = DispatchWorkItem { [weak self] in
                        finish(.failure(AdbConnectionError.timedOut))
                        self?.dispose()
                    }
                    queue.asyncAfter(deadline: deadline, execute: timer)
                    start { result in
                        timer.cancel()
                        finish(result)
                    }
                }
            } onCancel: { [weak self] in
                self?.dispose()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

// MARK: - Async lock

/// A mutual-exclusion lock for async code: waiters are suspended, not blocked, and served in
/// order. A waiter whose task is cancelled stops waiting with `CancellationError`.
final class AdbLock: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextId: UInt64 = 0

    func acquire() async throws {
        let id = lock.withLock {
            nextId += 1
            return nextId
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                // Cancellation is flagged before the handler below runs, and both take the
                // lock, so a cancel can't slip between them unnoticed.
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if !held {
                    held = true
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: index)
                lock.unlock()
                waiter.continuation.resume(throwing: CancellationError())
            } else {
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            held = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.continuation.resume() // the lock passes straight to it
        }
    }
}

// MARK: - Keys

enum AdbKeyError: LocalizedError {
    case malformed(String)
    case unsupported(String)
    case security(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let what): "Invalid ADB key: \(what)"
        case .unsupported(let what): "Unsupported ADB key: \(what)"
        case .security(let what): "Key operation failed: \(what)"
        }
    }
}

/// The RSA key that identifies this app to a TV.
///
/// It's stored (`TvDevice.adbKey`) as base64 of an unencrypted PKCS#8 PrivateKeyInfo, exactly
/// what TVControlForWin writes with `ExportPkcs8PrivateKey`, so a backup moves between the two
/// apps and the TV keeps recognising the key it approved. Security.framework only speaks
/// PKCS#1 for RSA, so the PKCS#8 envelope is put on and taken off here.
enum AdbKey {
    static let keyBits = 2048
    static let modulusBytes = keyBits / 8

    // 1.2.840.113549.1.1.1, rsaEncryption
    private static let rsaEncryptionOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    /// A new RSA-2048 key, base64 PKCS#8. Never touches the keychain.
    static func create() throws -> String {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: keyBits,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw AdbKeyError.security(describe(error))
        }
        return Data(try exportPkcs8(key)).base64EncodedString()
    }

    static func importPrivateKey(base64: String) throws -> SecKey {
        guard let der = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !der.isEmpty else {
            throw AdbKeyError.malformed("not base64")
        }
        return try importPrivateKey(pkcs8: Array(der))
    }

    static func importPrivateKey(pkcs8 der: [UInt8]) throws -> SecKey {
        let pkcs1 = try unwrapPkcs8(der)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error) else {
            throw AdbKeyError.malformed("not an RSA private key (\(describe(error)))")
        }
        return key
    }

    static func exportPkcs8(_ key: SecKey) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw AdbKeyError.security(describe(error))
        }
        return wrapPkcs8(pkcs1: Array(data))
    }

    /// PrivateKeyInfo ::= SEQUENCE { version INTEGER, privateKeyAlgorithm AlgorithmIdentifier,
    ///                               privateKey OCTET STRING, [0] attributes OPTIONAL, … }
    /// Returns the OCTET STRING's contents: the PKCS#1 RSAPrivateKey.
    static func unwrapPkcs8(_ der: [UInt8]) throws -> [UInt8] {
        var outer = DerReader(der)
        var info = DerReader(try outer.read(expecting: 0x30))
        guard outer.isAtEnd else { throw AdbKeyError.malformed("trailing bytes") }

        let version = try info.read(expecting: 0x02)
        guard version == [0] || version == [1] else { throw AdbKeyError.malformed("unknown PKCS#8 version") }

        var algorithm = DerReader(try info.read(expecting: 0x30))
        guard try algorithm.read(expecting: 0x06) == rsaEncryptionOid else {
            throw AdbKeyError.unsupported("not an RSA key")
        }
        if !algorithm.isAtEnd {
            let parameters = try algorithm.read()
            guard parameters.tag == 0x05, parameters.contents.isEmpty else {
                throw AdbKeyError.malformed("unexpected algorithm parameters")
            }
        }
        guard algorithm.isAtEnd else { throw AdbKeyError.malformed("unexpected algorithm parameters") }

        let privateKey = try info.read(expecting: 0x04)
        // Optional trailing fields ([0] attributes, [1] public key) carry nothing we need.
        while !info.isAtEnd {
            guard try info.read().tag & 0xC0 == 0x80 else { throw AdbKeyError.malformed("unexpected field") }
        }
        guard !privateKey.isEmpty else { throw AdbKeyError.malformed("empty private key") }
        return privateKey
    }

    /// The PKCS#8 envelope around a PKCS#1 RSAPrivateKey, field for field what .NET's
    /// `ExportPkcs8PrivateKey` writes (version 0, rsaEncryption with NULL parameters, no
    /// attributes).
    static func wrapPkcs8(pkcs1: [UInt8]) -> [UInt8] {
        let algorithm = DerReader.encode(0x30, DerReader.encode(0x06, rsaEncryptionOid) + DerReader.encode(0x05, []))
        let body = DerReader.encode(0x02, [0]) + algorithm + DerReader.encode(0x04, pkcs1)
        return DerReader.encode(0x30, body)
    }

    /// Signs ADB's 20-byte AUTH token. The token is treated as an already-computed SHA-1
    /// digest (what adbd verifies against), so this is the digest variant of PKCS#1 v1.5,
    /// not the one that hashes its input first.
    static func sign(token: [UInt8], with key: SecKey) throws -> [UInt8] {
        guard token.count == 20 else { throw AdbConnectionError.malformed("AUTH token of \(token.count) bytes") }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15SHA1,
                                                    Data(token) as CFData, &error) as Data? else {
            throw AdbKeyError.security(describe(error))
        }
        return Array(signature)
    }

    /// The modulus (big-endian, no sign byte) and public exponent of `key`.
    static func publicComponents(_ key: SecKey) throws -> (modulus: [UInt8], exponent: UInt32) {
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw AdbKeyError.security("no public key") }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw AdbKeyError.security(describe(error))
        }
        // RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
        var outer = DerReader(Array(data))
        var sequence = DerReader(try outer.read(expecting: 0x30))
        let modulus = Array(try sequence.read(expecting: 0x02).drop { $0 == 0 })
        let exponentBytes = Array(try sequence.read(expecting: 0x02).drop { $0 == 0 })
        guard exponentBytes.count <= 4, !exponentBytes.isEmpty else {
            throw AdbKeyError.unsupported("public exponent doesn't fit ADB's format")
        }
        let exponent = exponentBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (modulus, exponent)
    }

    /// ADB's public-key line minus the name: base64 of the key in ADB's own format.
    static func encodePublicKey(_ key: SecKey) throws -> String {
        let (modulus, exponent) = try publicComponents(key)
        return Data(try publicKeyStruct(modulus: modulus, exponent: exponent)).base64EncodedString()
    }

    /// ADB's own public-key format (Android's "mincrypt" RSAPublicKey struct):
    ///   uint32 length in 32-bit words (64), uint32 n0inv = -1/n mod 2^32,
    ///   n[64] and rr[64] = (2^2048)^2 mod n as little-endian words, uint32 exponent.
    /// The two derived values let the device verify with Montgomery multiplication. Neither
    /// needs a general bignum: see `n0inv` and `montgomeryRR`.
    static func publicKeyStruct(modulus: [UInt8], exponent: UInt32) throws -> [UInt8] {
        let n = try limbs(modulus: modulus)
        var out: [UInt8] = []
        out.reserveCapacity(4 + 4 + 2 * modulusBytes + 4)
        AdbClient.appendLE32(UInt32(n.count), to: &out)
        AdbClient.appendLE32(n0inv(n[0]), to: &out)
        for word in n { AdbClient.appendLE32(word, to: &out) }
        for word in montgomeryRR(n) { AdbClient.appendLE32(word, to: &out) }
        AdbClient.appendLE32(exponent, to: &out)
        return out
    }

    /// A 2048-bit modulus as 64 little-endian 32-bit limbs (limb 0 least significant).
    static func limbs(modulus: [UInt8]) throws -> [UInt32] {
        let bytes = Array(modulus.drop { $0 == 0 })
        guard bytes.count == modulusBytes, let top = bytes.first, top & 0x80 != 0,
              let bottom = bytes.last, bottom & 1 == 1 else {
            throw AdbKeyError.unsupported("ADB needs a 2048-bit RSA key")
        }
        var words = [UInt32](repeating: 0, count: modulusBytes / 4)
        for i in 0..<words.count {
            let o = modulusBytes - 4 * (i + 1)
            words[i] = UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])
        }
        return words
    }

    /// -n⁻¹ mod 2³² for an odd n0 (the lowest limb). Newton's iteration x ← x(2 − n0·x)
    /// doubles the number of correct low bits each round, and x = n0 starts with three
    /// (any odd n0 squares to 1 mod 8): 3 → 6 → 12 → 24 → 48 ≥ 32.
    static func n0inv(_ n0: UInt32) -> UInt32 {
        var x = n0
        for _ in 0..<4 { x = x &* (2 &- n0 &* x) }
        return 0 &- x
    }

    /// R² mod n with R = 2²⁰⁴⁸: start from 1 and double 4096 times, subtracting n whenever
    /// the value reaches it. The value stays below n, so after a doubling it's below 2n and
    /// one subtraction is always enough; the 2049th bit is carried separately.
    static func montgomeryRR(_ n: [UInt32]) -> [UInt32] {
        var value = [UInt32](repeating: 0, count: n.count)
        value[0] = 1
        for _ in 0..<(2 * 32 * n.count) {
            var carry: UInt32 = 0
            for i in 0..<value.count {
                let word = value[i]
                value[i] = word << 1 | carry
                carry = word >> 31
            }
            if carry != 0 || !isLess(value, n) { subtract(&value, n) }
        }
        return value
    }

    /// a < b for equal-length little-endian limb arrays.
    static func isLess(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] {
            return a[i] < b[i]
        }
        return false
    }

    /// a -= b modulo 2^(32·count).
    static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt32 = 0
        for i in 0..<a.count {
            let (d1, o1) = a[i].subtractingReportingOverflow(b[i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            a[i] = d2
            borrow = (o1 || o2) ? 1 : 0
        }
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error = error?.takeRetainedValue() else { return "unknown error" }
        return CFErrorCopyDescription(error) as String? ?? "unknown error"
    }
}

/// Just enough DER to walk a PKCS#8 or PKCS#1 structure. Every length is checked against
/// what's actually there, so a damaged key is an error, never a crash.
struct DerReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init(_ bytes: ArraySlice<UInt8>) { self.bytes = Array(bytes) }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func read() throws -> (tag: UInt8, contents: [UInt8]) {
        guard offset < bytes.count else { throw AdbKeyError.malformed("truncated") }
        let tag = bytes[offset]
        guard tag & 0x1F != 0x1F else { throw AdbKeyError.malformed("unsupported tag") }
        offset += 1

        guard offset < bytes.count else { throw AdbKeyError.malformed("truncated") }
        let first = bytes[offset]
        offset += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            // 0x80 is BER's indefinite length, never valid DER; more than 4 length bytes
            // would describe something far larger than any key.
            guard count >= 1, count <= 4, offset + count <= bytes.count else {
                throw AdbKeyError.malformed("bad length")
            }
            for _ in 0..<count {
                length = length << 8 | Int(bytes[offset])
                offset += 1
            }
        }
        guard length <= bytes.count - offset else { throw AdbKeyError.malformed("truncated") }
        let contents = Array(bytes[offset..<(offset + length)])
        offset += length
        return (tag, contents)
    }

    mutating func read(expecting tag: UInt8) throws -> [UInt8] {
        let element = try read()
        guard element.tag == tag else { throw AdbKeyError.malformed("unexpected structure") }
        return element.contents
    }

    static func encode(_ tag: UInt8, _ contents: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        let length = contents.count
        if length < 0x80 {
            out.append(UInt8(length))
        } else {
            var lengthBytes: [UInt8] = []
            var remaining = length
            while remaining > 0 {
                lengthBytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            out.append(0x80 | UInt8(lengthBytes.count))
            out.append(contentsOf: lengthBytes)
        }
        return out + contents
    }
}
