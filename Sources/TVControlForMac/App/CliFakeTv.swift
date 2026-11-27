// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Network
import Security

/// Hidden diagnostics command: stand-in TVs on 127.0.0.1, for walking the app's screens
/// through a TV's whole life without a real one (pairing needs a person at the TV, and
/// standby or a forgotten pairing can't be summoned on demand).
///
///   --fake-tv [options]
///
/// serves, on 127.0.0.1 only:
/// - a Google TV on 6467 (pairing) and 6466 (remote): the same `FakeTv` the self-test uses;
/// - an `adbd` on 5555 with a TCL-style `tcl_tv_display` service, for brightness setup;
/// - with `lg`, an LG webOS TV (SSAP over ws://, port 3000). Next to the Google TV, give it
///   its own address in devices.json (`localhost`, `"Kind": 0`): found by its ports, both
///   would look like one Google TV. With `lg-only` it's the only TV, for Add by IP Address.
///
/// Options: `vendor <name>` (default TCL; anything else and the app says "Power only"),
/// `approve <seconds>|never` (how long until "Allow USB debugging?" is answered, default 3),
/// `brightness <0-100>` (the TV's starting value, default 40), `trust <devices.json>` (accept
/// the certificate and ADB key saved there for 127.0.0.1, so a restart needn't pair again),
/// `lg` (also serve the LG TV), `lg-only` (serve only the LG TV), `lg-accept <seconds>|never`
/// (its pairing prompt, default 3).
///
/// Then type commands on stdin (or append them to a file piped in with `tail -f`):
/// `standby`, `wake`, `drop`, `forget`, `silent`, `loud`, `vendor <name>`,
/// `allow`, `approve <seconds>|never`, `adb-off`, `adb-on`, `adb-forget`, `adb-refuse on|off`,
/// `brightness <0-100>`, `lg-standby`, `lg-wake`, `lg-accept`, `lg-forget`, `status`, `quit`.
///
/// Every line it prints starts with the time, so a script can wait for one ("showing pairing
/// code 3F21A0").
enum FakeTvCli {
    static let commands: Set<String> = ["--fake-tv"]

    static func run(_ args: [String]) async {
        let options = Array(args.dropFirst())
        var vendor = "TCL"
        var approve: TimeInterval? = 3
        var brightness = 40
        var trustFile: String?
        var withLg = false
        var withGoogle = true
        var lgAccept: TimeInterval? = 3

        var i = 0
        func next() -> String? {
            i += 1
            return i < options.count ? options[i] : nil
        }
        while i < options.count {
            switch options[i] {
            case "vendor": vendor = next() ?? vendor
            case "approve": approve = next().flatMap(TimeInterval.init)
            case "brightness": brightness = next().flatMap(Int.init).map { max(0, min(100, $0)) } ?? brightness
            case "trust": trustFile = next()
            case "lg": withLg = true
            case "lg-only": withLg = true; withGoogle = false
            case "lg-accept": lgAccept = next().flatMap(TimeInterval.init)
            default:
                print("unknown option \(options[i])")
                print("usage: --fake-tv [vendor <name>] [approve <seconds>|never] [brightness <0-100>]")
                print("                 [trust <devices.json>] [lg | lg-only] [lg-accept <seconds>|never]")
                return
            }
            i += 1
        }

        var tv: FakeTv?
        let adb = FakeAdbd(brightness: brightness, approveAfter: approve)
        if withGoogle {
            do {
                tv = try await FakeTv.start()
            } catch {
                say("can't listen on 127.0.0.1:6466/6467 (\(error.localizedDescription))")
                return
            }
            tv?.vendor = vendor
            tv?.onEvent = { say("google tv: \($0)") }
            do {
                try await adb.listen()
            } catch {
                say("can't listen on 127.0.0.1:5555 (\(error.localizedDescription))")
                tv?.stop()
                return
            }
        }

        var lg: FakeLg?
        if withLg {
            let fake = FakeLg(brightness: brightness, acceptAfter: lgAccept)
            do {
                try await fake.listen()
                lg = fake
            } catch {
                say("can't listen on 127.0.0.1:3000 (\(error.localizedDescription))")
            }
        }

        if let trustFile, let tv { trust(trustFile, tv: tv, adb: adb) }

        say((tv != nil ? "google tv on 127.0.0.1:6466/6467, vendor \"\(vendor)\"; adbd on 127.0.0.1:5555 "
                + "(approves \(approve.map { "after \(Int($0)) s" } ?? "never")); " : "")
            + (lg != nil ? "LG on ws://127.0.0.1:3000" : "no LG"))
        say("ready; type commands (status, standby, wake, drop, forget, quit, …)")

        let lines = AsyncStream<String> { continuation in
            Thread.detachNewThread {
                while let line = readLine() { continuation.yield(line) }
                continuation.finish()
            }
        }
        var stdinClosed = true
        for await line in lines {
            stdinClosed = false
            let words = line.split(separator: " ").map(String.init)
            guard let command = words.first else { continue }
            let argument = words.count > 1 ? words[1] : nil
            switch command {
            case "quit", "exit":
                tv?.stop()
                adb.stop()
                lg?.stop()
                say("bye")
                return
            case "standby": tv?.setPower(on: false); say("google tv: standby")
            case "wake": tv?.setPower(on: true); say("google tv: on")
            case "drop": tv?.dropConnections(); adb.dropConnections(); say("dropped the connections")
            case "forget": tv?.forget(); say("google tv: forgot its paired certificate")
            case "silent": tv?.silent = true; say("google tv: silent (no pings, no reports)")
            case "loud": tv?.silent = false; say("google tv: talking again")
            case "vendor": tv?.vendor = argument ?? ""; say("google tv: vendor \"\(tv?.vendor ?? "")\" from the next connection")
            case "allow": adb.allowPending()
            case "approve": adb.approveAfter = argument.flatMap(TimeInterval.init); say("adb: approves \(adb.approveAfter.map { "after \(Int($0)) s" } ?? "never")")
            case "adb-off": adb.stop(); say("adb: off (USB debugging switched off)")
            case "adb-on":
                do { try await adb.listen(); say("adb: on") } catch { say("adb: can't listen (\(error.localizedDescription))") }
            case "adb-forget": adb.forget(); say("adb: forgot every approved key")
            case "adb-refuse": adb.refuse = argument != "off"; say("adb: brightness writes \(adb.refuse ? "refused" : "accepted")")
            case "brightness":
                if let value = argument.flatMap(Int.init) {
                    adb.brightness = value
                    lg?.brightness = value
                    say("brightness on the TV is now \(value)")
                }
            case "lg-standby": lg?.setPower("Active Standby")
            case "lg-wake": lg?.setPower("Active")
            case "lg-accept": lg?.acceptPending()
            case "lg-forget": lg?.forget()
            case "status":
                say((tv.map { "google tv: \($0.isOn ? "on" : "standby"), paired \($0.pairedCertificate != nil), "
                        + "keys \($0.keys), vendor \"\($0.vendor)\"; adb: brightness \(adb.brightness), "
                        + "approved keys \(adb.approvedCount), listening \(adb.isListening); " } ?? "")
                    + (lg.map { "lg: \($0.state), brightness \($0.brightness)" } ?? "no LG"))
            default:
                say("unknown command \(command)")
            }
        }
        // No stdin (started in the background): keep serving until killed.
        if stdinClosed { say("stdin closed; serving until stopped") }
        while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }

    // Accepts what an earlier run paired, read from the app's devices.json.
    private static func trust(_ path: String, tv: FakeTv, adb: FakeAdbd) {
        guard let data = FileManager.default.contents(atPath: path),
              let list = try? JSONDecoder().decode([TvDevice].self, from: data) else {
            say("can't read \(path)")
            return
        }
        for device in list where device.host == "127.0.0.1" {
            if let bytes = Data(base64Encoded: device.clientCertificate),
               let contents = try? Pkcs12.read(Array(bytes)) {
                tv.trust(contents.certificate, on: true)
                say("google tv: trusting the certificate saved for \(device.name)")
            }
            if !device.adbKey.isEmpty, let key = try? AdbKey.importPrivateKey(base64: device.adbKey),
               let (modulus, _) = try? AdbKey.publicComponents(key) {
                adb.approve(modulus: modulus)
                say("adb: trusting the key saved for \(device.name)")
            }
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static let printLock = NSLock()

    static func say(_ text: String) {
        printLock.withLock {
            print("\(clock.string(from: Date()))  \(text)")
            fflush(stdout)
        }
    }
}

// MARK: - adbd

/// Enough of `adbd` for the app's brightness: the CNXN/AUTH handshake with real signature
/// checks and an "Allow USB debugging?" that answers itself, and shell streams that run the
/// TCL `service` calls and the MAC lookup.
private final class FakeAdbd: @unchecked Sendable {
    private let queue = DispatchQueue(label: "faketv.adbd")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: AdbPeer] = [:]
    private var approved: [[UInt8]] = []                  // moduli, big-endian
    private var pending: [(peer: AdbPeer, modulus: [UInt8])] = []
    private var value: Int
    private var approveDelay: TimeInterval?
    private var refuseWrites = false

    init(brightness: Int, approveAfter: TimeInterval?) {
        value = brightness
        approveDelay = approveAfter
    }

    var brightness: Int {
        get { lock.withLock { value } }
        set { lock.withLock { value = max(0, min(100, newValue)) } }
    }
    var approveAfter: TimeInterval? {
        get { lock.withLock { approveDelay } }
        set { lock.withLock { approveDelay = newValue } }
    }
    var refuse: Bool {
        get { lock.withLock { refuseWrites } }
        set { lock.withLock { refuseWrites = newValue } }
    }
    var approvedCount: Int { lock.withLock { approved.count } }
    var isListening: Bool { lock.withLock { listener != nil } }

    func approve(modulus: [UInt8]) {
        lock.withLock { if !approved.contains(modulus) { approved.append(modulus) } }
    }

    func listen() async throws {
        guard !isListening else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: AdbClient.defaultPort)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.set() { continuation.resume() }
                case .failed(let e), .waiting(let e):
                    if once.set() { listener.cancel(); continuation.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener }
    }

    /// Stops listening and closes every connection: what switching USB debugging off does.
    func stop() {
        let old: NWListener? = lock.withLock {
            defer { listener = nil }
            return listener
        }
        old?.cancel()
        dropConnections()
    }

    func dropConnections() {
        let peers: [AdbPeer] = lock.withLock {
            defer { connections.removeAll(); pending.removeAll() }
            return Array(connections.values)
        }
        peers.forEach { $0.connection.cancel() }
    }

    /// Revokes every approval, as "Revoke USB debugging authorisations" does.
    func forget() {
        lock.withLock { approved.removeAll() }
        dropConnections()
    }

    /// Selects Allow on every dialog showing.
    func allowPending() {
        let waiting: [(peer: AdbPeer, modulus: [UInt8])] = lock.withLock {
            defer { pending.removeAll() }
            return pending
        }
        if waiting.isEmpty { FakeTvCli.say("adb: no dialog showing") }
        for (peer, modulus) in waiting { allow(peer, modulus) }
    }

    private func allow(_ peer: AdbPeer, _ modulus: [UInt8]) {
        approve(modulus: modulus)
        FakeTvCli.say("adb: Allow selected")
        peer.send(AdbClient.cmdConnect, AdbClient.protocolVersion, AdbClient.maxPayload,
                  Array("device::ro.product.name=fake;ro.product.model=FakeTV;\0".utf8))
    }

    private func accept(_ connection: NWConnection) {
        let peer = AdbPeer(connection: connection, queue: queue)
        lock.withLock { connections[ObjectIdentifier(peer)] = peer }
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            switch state {
            case .failed, .cancelled:
                guard let self, let peer else { return }
                self.lock.withLock {
                    self.connections[ObjectIdentifier(peer)] = nil
                    self.pending.removeAll { $0.peer === peer }
                }
            default: break
            }
        }
        connection.start(queue: queue)
        peer.receive { [weak self] message in self?.handle(message, from: peer) }
    }

    private func handle(_ message: AdbClient.Message, from peer: AdbPeer) {
        switch message.command {
        case AdbClient.cmdConnect:
            peer.token = Pkcs12Crypto.randomBytes(20)
            peer.send(AdbClient.cmdAuth, 1, 0, peer.token)

        case AdbClient.cmdAuth where message.arg0 == 2:
            let keys = lock.withLock { approved }
            if keys.contains(where: { verify(signature: message.payload, token: peer.token, modulus: $0) }) {
                FakeTvCli.say("adb: known key, connected")
                peer.send(AdbClient.cmdConnect, AdbClient.protocolVersion, AdbClient.maxPayload,
                          Array("device::ro.product.name=fake;ro.product.model=FakeTV;\0".utf8))
            } else {
                peer.token = Pkcs12Crypto.randomBytes(20)
                peer.send(AdbClient.cmdAuth, 1, 0, peer.token)
            }

        case AdbClient.cmdAuth where message.arg0 == 3:
            // "<base64 struct> <name>\0": the TV shows "Allow USB debugging?" for it.
            let text = String(decoding: message.payload.prefix { $0 != 0 }, as: UTF8.self)
            let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
            guard let blob = parts.first.flatMap({ Data(base64Encoded: $0) }), blob.count == 524 else {
                FakeTvCli.say("adb: malformed public key")
                peer.connection.cancel()
                return
            }
            let modulus = Array(Array(blob)[8..<264].reversed())
            let delay = approveAfter
            FakeTvCli.say("adb: showing \"Allow USB debugging?\" for \(parts.count > 1 ? parts[1] : "?")"
                          + (delay.map { ", Allow in \(Int($0)) s" } ?? ", nobody answers"))
            lock.withLock { pending.append((peer, modulus)) }
            if let delay {
                queue.asyncAfter(deadline: .now() + delay) { [weak self, weak peer] in
                    guard let self, let peer else { return }
                    let stillShowing: Bool = self.lock.withLock {
                        guard let index = self.pending.firstIndex(where: { $0.peer === peer }) else { return false }
                        self.pending.remove(at: index)
                        return true
                    }
                    if stillShowing { self.allow(peer, modulus) }
                }
            }

        case AdbClient.cmdOpen:
            let request = String(decoding: message.payload.prefix { $0 != 0 }, as: UTF8.self)
            let localId = message.arg0
            let remoteId = peer.nextStream()
            guard request.hasPrefix("shell:") else {
                peer.send(AdbClient.cmdClose, 0, localId, [])
                return
            }
            // service call replies come back a moment after the call, as they do on the TV.
            let output = shell(String(request.dropFirst(6)))
            peer.send(AdbClient.cmdOkay, remoteId, localId, [])
            if !output.isEmpty { peer.send(AdbClient.cmdWrite, remoteId, localId, Array(output.utf8)) }
            peer.send(AdbClient.cmdClose, remoteId, localId, [])

        default:
            break // OKAY for our writes, CLSE echoes
        }
    }

    private static let service = "tcl_tv_display"

    private func shell(_ command: String) -> String {
        func parcel(_ word: Int) -> String {
            String(format: "Result: Parcel(00000000 %08x   '........')\n", UInt32(truncatingIfNeeded: word))
        }
        if command.hasPrefix("service list") {
            return "152\t\(Self.service): [com.tcl.tv.display.ITvDisplayManagerService]\n"
        }
        if command == "service call \(Self.service) 101" {
            return parcel(brightness)
        }
        if command.hasPrefix("service call \(Self.service) 100 ") {
            let words = command.split(separator: " ")
            guard words.count == 10, let value = Int(words[7]) else { return parcel(0) }
            if refuse {
                FakeTvCli.say("adb: refused brightness \(value)")
                return parcel(0)
            }
            brightness = value
            FakeTvCli.say("adb: brightness set to \(value)")
            return parcel(1)
        }
        if command == AdbBrightness.macCommand {
            // No MAC: a made-up one would send Wake-on-LAN packets onto the real network.
            return ""
        }
        FakeTvCli.say("adb: shell \(command)")
        return "/system/bin/sh: \(command.split(separator: " ").first ?? ""): inaccessible or not found\n"
    }

    private func verify(signature: [UInt8], token: [UInt8], modulus: [UInt8]) -> Bool {
        let der = Der.sequence(Der.integer(unsigned: modulus), Der.integer(65537))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureDigestPKCS1v15SHA1, Data(token) as CFData,
                                     Data(signature) as CFData, nil)
    }
}

/// One ADB connection: framing in both directions.
private final class AdbPeer: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    var token: [UInt8] = []          // touched on `queue` only
    private var streams: UInt32 = 0  // likewise

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func nextStream() -> UInt32 {
        streams += 1
        return streams
    }

    func send(_ command: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ payload: [UInt8]) {
        connection.send(content: Data(AdbClient.frame(command, arg0, arg1, payload)), completion: .idempotent)
    }

    func receive(buffer: [UInt8] = [], _ handler: @escaping (AdbClient.Message) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer + (data.map { Array($0) } ?? [])
            while buffer.count >= 24 {
                guard let header = try? AdbClient.parseHeader(Array(buffer[0..<24])) else {
                    self.connection.cancel()
                    return
                }
                let total = 24 + Int(header.length)
                guard buffer.count >= total else { break }
                let payload = Array(buffer[24..<total])
                buffer.removeFirst(total)
                handler(AdbClient.Message(command: header.command, arg0: header.arg0, arg1: header.arg1,
                                          payload: payload))
            }
            if error == nil && !complete {
                self.receive(buffer: buffer, handler)
            } else {
                self.connection.cancel()
            }
        }
    }
}

// MARK: - LG webOS

/// Enough of an LG webOS TV for the app: SSAP over a plain WebSocket on 3000, with the
/// accept prompt, the backlight read and the alert-routed write, power state, screen off
/// and turn off.
private final class FakeLg: @unchecked Sendable {
    private let queue = DispatchQueue(label: "faketv.lg")
    private let lock = NSLock()
    private var listener: NWListener?
    private var sockets: [NWConnection] = []
    private var keys: Set<String> = []
    private var promptShowing: [(NWConnection, String)] = []
    private var alerts: [String: Int] = [:]
    private var value: Int
    private var power = "Active"
    private let acceptAfter: TimeInterval?
    private var nextAlert = 0

    init(brightness: Int, acceptAfter: TimeInterval?) {
        value = brightness
        self.acceptAfter = acceptAfter
    }

    var brightness: Int {
        get { lock.withLock { value } }
        set { lock.withLock { value = max(0, min(100, newValue)) } }
    }
    var state: String { lock.withLock { power } }

    func listen() async throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 3000)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.set() { continuation.resume() }
                case .failed(let e), .waiting(let e):
                    if once.set() { listener.cancel(); continuation.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener }
    }

    func stop() {
        let (old, open): (NWListener?, [NWConnection]) = lock.withLock {
            defer { listener = nil; sockets.removeAll() }
            return (listener, sockets)
        }
        old?.cancel()
        open.forEach { $0.cancel() }
    }

    /// "Active", "Screen Off" or "Active Standby"; a TV in standby keeps the socket open
    /// (Quick Start+) and only says so when asked.
    func setPower(_ state: String) {
        lock.withLock { power = state }
        FakeTvCli.say("lg: \(state)")
    }

    func acceptPending() {
        let waiting: [(NWConnection, String)] = lock.withLock {
            defer { promptShowing.removeAll() }
            return promptShowing
        }
        if waiting.isEmpty { FakeTvCli.say("lg: no prompt showing") }
        for (socket, id) in waiting { register(socket, id: id) }
    }

    func forget() {
        let open: [NWConnection] = lock.withLock {
            keys.removeAll()
            return sockets
        }
        open.forEach { $0.cancel() }
        FakeTvCli.say("lg: forgot every client key")
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { sockets.append(connection) }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.lock.withLock { self?.sockets.removeAll { $0 === connection } }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty,
               let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.handle(message, on: connection)
            }
            if error == nil { self.receive(connection) } else { connection.cancel() }
        }
    }

    private func send(_ connection: NWConnection, _ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ssap", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func register(_ connection: NWConnection, id: String) {
        let key = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        lock.withLock { _ = keys.insert(key) }
        FakeTvCli.say("lg: prompt accepted")
        send(connection, ["type": "registered", "id": id, "payload": ["client-key": key]])
    }

    private func handle(_ message: [String: Any], on connection: NWConnection) {
        let id = message["id"] as? String ?? ""
        let payload = message["payload"] as? [String: Any] ?? [:]
        if message["type"] as? String == "register" {
            let key = payload["client-key"] as? String ?? ""
            if !key.isEmpty, lock.withLock({ keys.contains(key) }) {
                send(connection, ["type": "registered", "id": id, "payload": ["client-key": key]])
                return
            }
            send(connection, ["type": "response", "id": id, "payload": ["pairingType": "PROMPT", "returnValue": true]])
            FakeTvCli.say("lg: showing the accept prompt" + (acceptAfter.map { ", accepted in \(Int($0)) s" } ?? ""))
            lock.withLock { promptShowing.append((connection, id)) }
            if let delay = acceptAfter {
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    let showing: Bool = self.lock.withLock {
                        guard let index = self.promptShowing.firstIndex(where: { $0.0 === connection }) else { return false }
                        self.promptShowing.remove(at: index)
                        return true
                    }
                    if showing { self.register(connection, id: id) }
                }
            }
            return
        }

        let uri = message["uri"] as? String ?? ""
        func reply(_ body: [String: Any]) {
            send(connection, ["type": "response", "id": id, "payload": body.merging(["returnValue": true]) { a, _ in a }])
        }
        switch uri {
        case SsapPayloads.getSystemSettings:
            reply(["settings": ["backlight": String(brightness)]])
        case SsapPayloads.createAlert:
            let settings = ((payload["onclose"] as? [String: Any])?["params"] as? [String: Any])?["settings"] as? [String: Any]
            let wanted = (settings?["backlight"] as? String).flatMap(Int.init)
            let alertId: String = lock.withLock {
                nextAlert += 1
                let alertId = "alert-\(nextAlert)"
                if let wanted { alerts[alertId] = wanted }
                return alertId
            }
            reply(["alertId": alertId])
        case SsapPayloads.closeAlert:
            let alertId = payload["alertId"] as? String ?? ""
            if let wanted = lock.withLock({ alerts.removeValue(forKey: alertId) }) {
                brightness = wanted
                FakeTvCli.say("lg: backlight set to \(wanted)")
            }
            reply([:])
        case SsapPayloads.getPowerState:
            reply(["state": state])
        case SsapPayloads.turnOffScreen, SsapPayloads.turnOffScreenLegacy:
            setPower("Screen Off")
            reply([:])
        case SsapPayloads.turnOnScreen, SsapPayloads.turnOnScreenLegacy:
            setPower("Active")
            reply([:])
        case SsapPayloads.turnOff:
            // The TV goes dark; with Quick Start+ the socket lives on in standby.
            setPower("Active Standby")
            reply([:])
        case SsapPayloads.getConnectionInfo:
            reply([:]) // no MAC: a made-up one would send Wake-on-LAN onto the real network
        default:
            send(connection, ["type": "error", "id": id, "error": "404 no such service or method", "payload": [:]])
        }
    }
}
