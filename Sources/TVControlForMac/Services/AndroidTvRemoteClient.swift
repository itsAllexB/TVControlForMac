// SPDX-License-Identifier: AGPL-3.0-or-later
import CryptoKit
import Foundation
import Network
import Security

// Android TV Remote protocol v2: what the Google TV phone remote speaks, and what every
// Android TV / Google TV set (TCL, Sony, Philips, Hisense, Xiaomi, Chromecast, Shield…)
// answers on the LAN. Two TLS ports, both authenticated by a self-signed client certificate:
//
//   6467  pairing: the TV shows a 6-character code; we prove we saw it by sending a hash of
//         both certificates' public keys plus the code. After that the TV trusts our cert.
//   6466  remote:  key presses out, power / volume state back, with a ping every few seconds.
//
// Messages are protobuf, each preceded by its varint length (see ProtoWire.swift).
// Prior art: tronikos/androidtvremote2 (what Home Assistant uses).

/// What went wrong talking to a TV. The cases matter to the controller, which tells
/// "the TV is off" from "the TV turned down our certificate" from "the connection broke".
enum AndroidTvError: LocalizedError {
    /// No TCP connection: refused, no route, or nobody answered in time. The TV is off,
    /// asleep with its network down, or the address is wrong.
    case unreachable(String)
    /// A step didn't finish in the time it's allowed.
    case timedOut(String)
    /// TLS failed, with the Security framework's status (an errSSL… code) and
    /// Network.framework's own description of the error.
    case tls(OSStatus, detail: String)
    /// The TV closed the connection.
    case closed
    /// The connection broke for another reason.
    case connectionLost(String)
    /// The TV answered a pairing step with an error status.
    case refused(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .unreachable(let why): "Can't reach the TV (\(why))"
        case .timedOut(let what): "\(what) timed out"
        case .tls(let status, _): "TLS error \(status) (\(Self.tlsName(status)))"
        case .closed: "The TV closed the connection."
        case .connectionLost(let why): why
        case .refused(let why): why
        case .notConnected: "Not connected."
        }
    }

    /// The TV is off or the address is wrong, as opposed to a connection that broke later.
    /// A timed-out connect counts: an off TV often just doesn't answer.
    var isUnreachable: Bool {
        switch self {
        case .unreachable, .timedOut: true
        default: false
        }
    }

    /// The TLS alerts a TV sends when it doesn't know our certificate. Measured on a TCL
    /// 65C765 (Android 14) with a certificate it never paired with: the TV sends
    /// bad_certificate, which Network.framework reports as errSSLPeerBadCert (-9825,
    /// "misc. bad certificate"). Under TLS 1.3 (what it negotiates) the handshake itself
    /// completes and the alert arrives on the first read; capped at TLS 1.2 the handshake
    /// fails with it. The others are what other TV stacks may send for the same thing
    /// (TVControlForWin matches Windows' "cert unknown" and "untrusted root", i.e.
    /// certificate_unknown and unknown_ca). A plain close, reset or timeout is deliberately
    /// *not* here: that's also what a TV going to sleep looks like, and dropping a good
    /// certificate costs a re-pair at the TV.
    static let rejectionStatuses: Set<OSStatus> = [
        errSSLPeerCertUnknown,  // alert 46 certificate_unknown
        errSSLPeerBadCert,      // alert 42 bad_certificate
        errSSLPeerUnknownCA,    // alert 48 unknown_ca
        errSSLPeerAccessDenied, // alert 49 access_denied
    ]

    var isCertificateRejected: Bool {
        if case .tls(let status, _) = self { return Self.rejectionStatuses.contains(status) }
        return false
    }

    static func tlsName(_ status: OSStatus) -> String {
        switch status {
        case errSSLPeerCertUnknown: "errSSLPeerCertUnknown"
        case errSSLPeerBadCert: "errSSLPeerBadCert"
        case errSSLPeerUnknownCA: "errSSLPeerUnknownCA"
        case errSSLPeerAccessDenied: "errSSLPeerAccessDenied"
        case errSSLPeerHandshakeFail: "errSSLPeerHandshakeFail"
        case errSSLClosedAbort: "errSSLClosedAbort"
        case errSSLClosedGraceful: "errSSLClosedGraceful"
        case errSSLClosedNoNotify: "errSSLClosedNoNotify"
        case errSSLTransportReset: "errSSLTransportReset"
        case errSSLCertificateRequired: "errSSLCertificateRequired"
        default: SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        }
    }
}

/// The pairing code the user typed can't be the one the TV is showing.
struct PairingCodeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - TLS transport

/// One TLS connection to a TV, presenting our client certificate and accepting the TV's own
/// self-signed one as-is (trust comes from the pairing code). Reads whole protobuf frames.
///
/// Every wait is bounded: a read or write that runs out of time cancels the connection,
/// which is the only way to stop a pending Network.framework receive. That's fine for every
/// caller, since a TV that doesn't answer in time is treated as gone anyway.
final class AndroidTvTlsConnection: @unchecked Sendable {
    static let remotePort: UInt16 = TvControllerFactory.androidTvRemotePort
    static let pairingPort: UInt16 = 6467

    /// A write gets this long to be accepted by the network stack. It normally completes at
    /// once; only a connection whose send buffer is jammed (the TV vanished) takes longer.
    private static let writeTimeout: TimeInterval = 10

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "TVControlForMac.AndroidTvTls")
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var bufferStart = 0
    private var timedOutStep: String?
    private var closedByUs = false
    private var ready = false
    private let peer = PeerInfo()

    /// What the verify block learns about the TV during the handshake. Its own object, so
    /// the block can be installed before the connection (and `self`) exist.
    private final class PeerInfo: @unchecked Sendable {
        let lock = NSLock()
        var certificate: SecCertificate?
        var version: tls_protocol_version_t?
    }

    /// The TV's certificate, as presented during the handshake.
    var serverCertificate: SecCertificate? {
        peer.lock.lock(); defer { peer.lock.unlock() }
        return peer.certificate
    }

    /// "TLS 1.3" etc., for diagnostics.
    var tlsVersion: String {
        peer.lock.lock(); defer { peer.lock.unlock() }
        switch peer.version {
        case .TLSv13?: return "TLS 1.3"
        case .TLSv12?: return "TLS 1.2"
        case .none: return "TLS ?"
        default: return "TLS (older)"
        }
    }

    private init(host: String, port: UInt16, credential: AndroidTvCredential,
                 maxVersion: tls_protocol_version_t?, connectTimeout: TimeInterval) {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        if let identity = sec_identity_create(credential.identity) {
            sec_protocol_options_set_local_identity(options, identity)
        }
        if let maxVersion { sec_protocol_options_set_max_tls_protocol_version(options, maxVersion) }
        // Network.framework resumes TLS 1.2 sessions to the same host and port by default. A
        // resumed handshake exchanges no certificates, so the verify block below never runs
        // and pairing has no server key to hash: every other attempt on a TLS 1.2 TV would
        // fail with "presented no certificate". Measured over loopback (see the self-test).
        sec_protocol_options_set_tls_resumption_enabled(options, false)

        // The TV's certificate is self-signed: accept it, but keep it, since the pairing
        // secret is computed over its public key.
        let peer = peer
        sec_protocol_options_set_verify_block(options, { metadata, trust, complete in
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            let leaf = (SecTrustCopyCertificateChain(trustRef) as? [SecCertificate])?.first
            let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata)
            peer.lock.lock()
            peer.certificate = leaf
            peer.version = version
            peer.lock.unlock()
            complete(true)
        }, queue)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // A second past our own deadline: the TCP stack is only the backstop, so a TV that
        // never answers reads as a timeout (as in TVControlForWin) rather than racing it.
        tcp.connectionTimeout = max(1, Int(connectTimeout.rounded(.up)) + 1)

        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port) ?? 6466,
                                  using: NWParameters(tls: tls, tcp: tcp))
    }

    /// Connects and completes the TLS handshake within `timeout`.
    /// `maxVersion` caps the TLS version (diagnostics only).
    static func open(host: String, port: UInt16, credential: AndroidTvCredential, timeout: TimeInterval,
                     maxVersion: tls_protocol_version_t? = nil) async throws -> AndroidTvTlsConnection {
        try Task.checkCancellation()
        let tls = AndroidTvTlsConnection(host: host, port: port, credential: credential,
                                         maxVersion: maxVersion, connectTimeout: timeout)
        try await tls.start(timeout: timeout)
        return tls
    }

    private func start(timeout: TimeInterval) async throws {
        let finished = OnceFlag()
        let connection = connection
        let outcome: NWError? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWError?, Error>) in
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.markReady()
                        if finished.set() { continuation.resume(returning: nil) }
                    case .waiting(let error):
                        // Network.framework would keep retrying (refused, no route…); a TV
                        // that isn't there now is the caller's to retry, with its own backoff.
                        if finished.set() {
                            connection.cancel()
                            continuation.resume(returning: error)
                        }
                    case .failed(let error):
                        if finished.set() { continuation.resume(returning: error) }
                        connection.cancel()
                    case .cancelled:
                        if finished.set() { continuation.resume(returning: nil) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard finished.set() else { return }
                    self?.markTimedOut("Connecting")
                    connection.cancel()
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            connection.cancel()
        }

        if let step = takeTimedOut() { throw AndroidTvError.timedOut(step) }
        if Task.isCancelled { connection.cancel(); throw CancellationError() }
        if let outcome { throw translate(outcome, connecting: true) }
        guard isReady else { throw AndroidTvError.connectionLost("The connection closed while connecting.") }
    }

    /// Reads one length-prefixed message, waiting at most `timeout` for all of it.
    func readFrame(timeout: TimeInterval, step: String = "Waiting for the TV") async throws -> [UInt8] {
        guard timeout > 0 else { throw AndroidTvError.timedOut(step) }
        let timer = arm(timeout, step)
        defer { timer.cancel() }
        return try await ProtoFraming.read(
            nextByte: { try await self.take(1)[0] },
            nextBytes: { try await self.take($0) })
    }

    /// Sends one message, length-prefixed, as a single write.
    func writeFrame(_ message: [UInt8]) async throws {
        let timer = arm(Self.writeTimeout, "Sending to the TV")
        defer { timer.cancel() }
        let connection = connection
        let error: NWError? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<NWError?, Never>) in
                connection.send(content: Data(ProtoFraming.frame(message)),
                                completion: .contentProcessed { continuation.resume(returning: $0) })
            }
        } onCancel: {
            connection.cancel()
        }
        if let error { throw translate(error, connecting: false) }
        if let step = takeTimedOut() { throw AndroidTvError.timedOut(step) }
    }

    func close() {
        lock.withLock { closedByUs = true }
        connection.cancel()
    }

    // MARK: Internals

    private var isReady: Bool { lock.withLock { ready } }

    private func markReady() {
        lock.withLock { ready = true }
    }

    private func markTimedOut(_ step: String) {
        lock.withLock { if timedOutStep == nil { timedOutStep = step } }
    }

    private func takeTimedOut() -> String? {
        lock.withLock { timedOutStep }
    }

    private func arm(_ timeout: TimeInterval, _ step: String) -> DispatchWorkItem {
        let item = DispatchWorkItem { [weak self] in
            self?.markTimedOut(step)
            self?.connection.cancel()
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: item)
        return item
    }

    /// Exactly `count` bytes from the stream, receiving more as needed.
    private func take(_ count: Int) async throws -> [UInt8] {
        while true {
            let ready: [UInt8]? = lock.withLock {
                guard buffer.count - bufferStart >= count else { return nil }
                let out = Array(buffer[bufferStart..<(bufferStart + count)])
                bufferStart += count
                if bufferStart == buffer.count {
                    buffer.removeAll(keepingCapacity: true)
                    bufferStart = 0
                }
                return out
            }
            if let ready { return ready }
            try await receiveMore()
        }
    }

    private func receiveMore() async throws {
        let connection = connection
        let (data, complete, error): (Data?, Bool, NWError?) = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(Data?, Bool, NWError?), Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    continuation.resume(returning: (data, isComplete, error))
                }
            }
        } onCancel: {
            connection.cancel()
        }

        if let data, !data.isEmpty {
            lock.withLock {
                if bufferStart > 0 {
                    buffer.removeFirst(bufferStart)
                    bufferStart = 0
                }
                buffer.append(contentsOf: data)
            }
            return
        }
        if let step = takeTimedOut() { throw AndroidTvError.timedOut(step) }
        if Task.isCancelled { throw CancellationError() }
        if let error { throw translate(error, connecting: false) }
        if complete { throw AndroidTvError.closed }
    }

    /// Network.framework's error → ours. Only connect-phase network errors mean "unreachable";
    /// anything after the TCP connection was up means the TV was there.
    private func translate(_ error: NWError, connecting: Bool) -> Error {
        if let step = takeTimedOut() { return AndroidTvError.timedOut(step) }
        if lock.withLock({ closedByUs }) { return AndroidTvError.connectionLost("Connection closed.") }

        switch error {
        case .tls(let status):
            return AndroidTvError.tls(status, detail: String(describing: error))
        case .dns(let code):
            return AndroidTvError.unreachable("DNS error \(code)")
        case .posix(let code):
            let unreachableCodes: Set<POSIXErrorCode> = [.ECONNREFUSED, .ETIMEDOUT, .EHOSTUNREACH,
                                                         .ENETUNREACH, .EHOSTDOWN, .ENETDOWN, .EADDRNOTAVAIL]
            if connecting && unreachableCodes.contains(code) {
                return AndroidTvError.unreachable(String(describing: error))
            }
            return AndroidTvError.connectionLost(String(describing: error))
        default:
            return AndroidTvError.connectionLost(String(describing: error))
        }
    }
}

// MARK: - Pairing

/// One pairing attempt on port 6467. `start` makes the TV display its code; `finish`
/// submits what the user typed. `close` dismisses the code.
final class AndroidTvPairingSession {
    private static let statusOk: UInt64 = 200
    private static let hexEncoding: UInt64 = 3
    private static let codeLength = 6
    private static let inputRole: UInt64 = 1

    private let tls: AndroidTvTlsConnection
    private let credential: AndroidTvCredential

    private init(tls: AndroidTvTlsConnection, credential: AndroidTvCredential) {
        self.tls = tls
        self.credential = credential
    }

    /// Connects and negotiates up to the point where the TV is showing its pairing code, all
    /// within `timeout`. `clientName` is the name the TV displays for this app.
    static func start(host: String, credential: AndroidTvCredential, clientName: String,
                      timeout: TimeInterval) async throws -> AndroidTvPairingSession {
        let deadline = Date().addingTimeInterval(timeout)
        let tls = try await AndroidTvTlsConnection.open(host: host, port: AndroidTvTlsConnection.pairingPort,
                                                        credential: credential, timeout: timeout)
        let session = AndroidTvPairingSession(tls: tls, credential: credential)
        do {
            let encoding = ProtoWriter().withVarint(1, hexEncoding).withVarint(2, UInt64(codeLength))

            // pairing_request → pairing_request_ack
            try await session.exchange(10, ProtoWriter().withString(1, "atvremote").withString(2, clientName),
                                       deadline: deadline)
            // pairing_option: we take a 6-digit hex code as input → the TV echoes its options
            try await session.exchange(20, ProtoWriter().withMessage(1, encoding).withVarint(3, inputRole),
                                       deadline: deadline)
            // pairing_configuration → ack, and the code appears on screen
            try await session.exchange(30, ProtoWriter().withMessage(1, encoding).withVarint(2, inputRole),
                                       deadline: deadline)
            return session
        } catch {
            session.close()
            throw error
        }
    }

    /// The TLS version the TV negotiated (diagnostics).
    var tlsVersion: String { tls.tlsVersion }

    /// Submits the code shown on the TV. Throws `PairingCodeError`, leaving the session usable
    /// for another try, when the code is mistyped, which is detectable locally: its first
    /// byte must equal the first byte of the secret hash.
    func finish(code: String, timeout: TimeInterval) async throws {
        let code = String(code.filter { !$0.isWhitespace }).uppercased()
        guard code.count == Self.codeLength, code.allSatisfy(\.isHexDigit), let codeBytes = Self.hexBytes(code) else {
            throw PairingCodeError(message: "Codes have 6 characters, 0 to 9 and A to F")
        }

        let secret = try computeSecret(codeBytes)
        guard secret.first == codeBytes.first else {
            throw PairingCodeError(message: "Wrong code. Try again")
        }

        // pairing_secret → pairing_secret_ack
        try await exchange(40, ProtoWriter().withBytes(1, secret), deadline: Date().addingTimeInterval(timeout))
    }

    func close() { tls.close() }

    // SHA-256 over both RSA public keys (client then server, modulus then exponent, as
    // minimal big-endian integers) followed by the last two bytes of the code.
    private func computeSecret(_ codeBytes: [UInt8]) throws -> [UInt8] {
        guard let serverCertificate = tls.serverCertificate else {
            throw AndroidTvError.connectionLost("The TV presented no certificate.")
        }
        let client = try AndroidTvIdentity.rsaPublicKey(credential.certificate)
        let server = try AndroidTvIdentity.rsaPublicKey(serverCertificate)

        var hash = SHA256()
        hash.update(data: client.modulus)
        hash.update(data: client.exponent)
        hash.update(data: server.modulus)
        hash.update(data: server.exponent)
        hash.update(data: Array(codeBytes.dropFirst()))
        return Array(hash.finalize())
    }

    // Sends one pairing step (wrapped in the protocol-version + status envelope) and reads the
    // TV's answer, which must carry status 200.
    private func exchange(_ field: Int, _ body: ProtoWriter, deadline: Date) async throws {
        let message = ProtoWriter().withVarint(1, 2).withVarint(2, Self.statusOk).withMessage(field, body)
        try await tls.writeFrame(message.bytes)

        let reply = try ProtoMessage.parse(try await tls.readFrame(timeout: deadline.timeIntervalSinceNow,
                                                                   step: "Pairing"))
        let status = reply.varint(2) ?? 0
        guard status == Self.statusOk else {
            throw AndroidTvError.refused("The TV refused the pairing step (status \(status)).")
        }
    }

    private static func hexBytes(_ hex: String) -> [UInt8]? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }
}

// MARK: - Remote

/// The remote-control connection on port 6466: sends key presses and tracks whether the TV is
/// on. One instance == one connection; create a new one to reconnect.
final class AndroidTvRemoteClient: @unchecked Sendable {
    /// KEYCODE_POWER: a toggle, so only send it when `isOn` says which way it'll go.
    static let keyPower = 26

    // Feature bits we claim in the handshake: key | ime | voice | power | volume | app-link.
    // The same value the reference clients send; the TV only reports power state when asked.
    private static let features: UInt64 = 622

    // The TV pings every ~5 s. Going this long without hearing anything means the connection
    // is dead even if TCP hasn't noticed, e.g. the TV lost power.
    private static let idleTimeout: TimeInterval = 20

    private static let handshakeTimeout: TimeInterval = 6
    private static let shortPress: UInt64 = 3

    private let lock = NSLock()
    private var tls: AndroidTvTlsConnection?
    private var connected = false
    private var disposed = false
    private var on: Bool?
    private var modelName = ""
    private var vendorName = ""

    var isConnected: Bool { lock.withLock { connected } }

    /// Whether the TV is on (true), in standby (false), or hasn't said yet (nil).
    var isOn: Bool? { lock.withLock { on } }

    /// Model and vendor as reported by the TV in the handshake, e.g. "Smart TV Pro" / "TCL".
    var model: String { lock.withLock { modelName } }
    var vendor: String { lock.withLock { vendorName } }

    /// The TLS version in use (diagnostics).
    var tlsVersion: String { lock.withLock { tls }?.tlsVersion ?? "TLS ?" }

    /// Called from the receive loop whenever the TV reports its power state.
    var onPowerChanged: ((Bool) -> Void)?
    /// Called for each ping the TV sends (diagnostics).
    var onPing: ((UInt64) -> Void)?

    /// Connects and completes the handshake. Success means the TV accepted our certificate; a TV
    /// we aren't paired with drops the connection instead, surfacing here as an error.
    /// `maxVersion` caps the TLS version (diagnostics only).
    func connect(host: String, credential: AndroidTvCredential,
                 maxVersion: tls_protocol_version_t? = nil) async throws {
        let deadline = Date().addingTimeInterval(Self.handshakeTimeout)
        let tls = try await AndroidTvTlsConnection.open(host: host, port: AndroidTvTlsConnection.remotePort,
                                                        credential: credential, timeout: Self.handshakeTimeout,
                                                        maxVersion: maxVersion)
        let gone: Bool = lock.withLock {
            if !disposed { self.tls = tls }
            return disposed
        }
        if gone {
            tls.close()
            throw AndroidTvError.connectionLost("Connection closed.")
        }

        // The TV speaks first (remote_configure). Wait for that one message before declaring
        // the connection good: it's the proof the certificate was accepted.
        let first = try ProtoMessage.parse(try await tls.readFrame(timeout: deadline.timeIntervalSinceNow,
                                                                   step: "Handshake"))
        lock.withLock { connected = !disposed }
        try await handle(first)
    }

    /// Pumps incoming messages until the connection ends, which it reports by throwing
    /// (`AndroidTvError` on a drop or silence, `CancellationError` when the task is cancelled).
    func run() async throws {
        guard let tls = lock.withLock({ self.tls }) else { throw AndroidTvError.notConnected }
        defer { lock.withLock { connected = false } }

        while true {
            let frame: [UInt8]
            do {
                frame = try await tls.readFrame(timeout: Self.idleTimeout)
            } catch AndroidTvError.timedOut {
                throw AndroidTvError.connectionLost("The TV stopped responding.")
            }
            try await handle(try ProtoMessage.parse(frame))
        }
    }

    private func handle(_ message: ProtoMessage) async throws {
        if let configure = message.message(1) {
            // remote_configure: the TV introduces itself; answer with who we are.
            let info = configure.message(2)
            lock.withLock {
                modelName = info?.string(1) ?? ""
                vendorName = info?.string(2) ?? ""
            }
            try await send(ProtoWriter().withMessage(1, ProtoWriter()
                .withVarint(1, Self.features)
                .withMessage(2, ProtoWriter()
                    .withVarint(3, 1)
                    .withString(4, "1")
                    .withString(5, "atvremote")
                    .withString(6, "1.0.0"))))
        } else if message.has(2) {
            // remote_set_active: confirm the feature set.
            try await send(ProtoWriter().withMessage(2, ProtoWriter().withVarint(1, Self.features)))
        } else if let ping = message.message(8) {
            // remote_ping_request → remote_ping_response echoing its counter.
            let counter = ping.varint(1) ?? 0
            try await send(ProtoWriter().withMessage(9, ProtoWriter().withVarint(1, counter)))
            onPing?(counter)
        } else if let start = message.message(40) {
            // remote_start { started }: proto3 omits false, so an empty message means standby.
            let isOn = (start.varint(1) ?? 0) != 0
            lock.withLock { on = isOn }
            onPowerChanged?(isOn)
        }
        // Everything else (volume, current app, IME state) is ignored.
    }

    /// Sends a single key press (an Android KEYCODE_* value).
    func sendKey(_ keyCode: Int) async throws {
        try await send(ProtoWriter().withMessage(10, ProtoWriter()
            .withVarint(1, UInt64(max(0, keyCode)))
            .withVarint(2, Self.shortPress)))
    }

    /// Waits until the TV reports the given power state. False if it didn't in time.
    func waitForPower(on wanted: Bool, timeout: TimeInterval) async throws -> Bool {
        var waited: TimeInterval = 0
        while waited < timeout {
            if isOn == wanted { return true }
            if !isConnected { return false }
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        return isOn == wanted
    }

    /// Waits for the first power report after connecting (it trails the handshake by a
    /// moment). Returns `isOn`, still nil if the TV never said.
    func waitForPowerReport(timeout: TimeInterval) async throws -> Bool? {
        var waited: TimeInterval = 0
        while waited < timeout, isOn == nil, isConnected {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        return isOn
    }

    // Network.framework keeps sends in order and each frame goes out as one send, so frames
    // from the receive loop (ping replies) and from callers (key presses) can't interleave;
    // the C# needed a send lock for that, this doesn't.
    private func send(_ message: ProtoWriter) async throws {
        let (tls, live) = lock.withLock { (self.tls, connected) }
        guard let tls, live else { throw AndroidTvError.notConnected }
        try await tls.writeFrame(message.bytes)
    }

    func dispose() {
        let tls: AndroidTvTlsConnection? = lock.withLock {
            disposed = true
            connected = false
            defer { self.tls = nil }
            return self.tls
        }
        tls?.close()
    }
}
