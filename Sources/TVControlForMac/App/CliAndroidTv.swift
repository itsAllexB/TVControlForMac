// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Network
import Security

/// Hidden diagnostics commands for Google TV (Android TV Remote protocol). `CliMode` hands over any argument
/// listed in `commands`.
///
///   --atv-pair <host>                      pair: the TV shows a code, type it here; saved on the device
///   --atv-probe <host> [seconds]           connect with the saved certificate, report vendor/model/power/pings
///   --atv-power <host> on|off|toggle       power through the production controller
///   --atv-unpaired <host> [port] [tls12]   connect with a brand-new (unpaired) certificate, print the error
///   --atv-pfx-new <out.p12>                make a client certificate, write it as PKCS#12 (no password)
///   --atv-pfx-read <file>                  load a PKCS#12 (DER, base64, or a devices/backup JSON)
///   --atv-selftest [slow]                  offline checks incl. a fake TV on 127.0.0.1, PASS/FAIL per check
///                                          ("slow" adds the ~1 min silent-TV scenarios)
enum AtvCli {
    /// The first-argument flags this handles, e.g. "--example".
    static let commands: Set<String> = [
        "--atv-pair", "--atv-probe", "--atv-power", "--atv-unpaired",
        "--atv-pfx-new", "--atv-pfx-read", "--atv-selftest",
    ]

    /// Runs the command in `args` (args[0] is the flag). Prints its own output.
    static func run(_ args: [String]) async {
        switch (args.first ?? "", args.count) {
        case ("--atv-pair", 2...): await pair(host: args[1])
        case ("--atv-probe", 2...): await probe(host: args[1], seconds: args.count > 2 ? Double(args[2]) ?? 10 : 10)
        case ("--atv-power", 3...): await power(host: args[1], action: args[2])
        case ("--atv-unpaired", 2...):
            let port = args.dropFirst(2).compactMap { UInt16($0) }.first ?? AndroidTvTlsConnection.remotePort
            await unpaired(host: args[1], port: port, tls12: args.contains("tls12"))
        case ("--atv-pfx-new", 2...): pfxNew(path: args[1])
        case ("--atv-pfx-read", 2...): pfxRead(path: args[1])
        case ("--atv-selftest", _): await AtvSelfTest.run(slow: args.contains("slow"))
        default:
            print("usage: --atv-pair <host> | --atv-probe <host> [seconds] | --atv-power <host> on|off|toggle |")
            print("       --atv-unpaired <host> [port] [tls12] | --atv-pfx-new <out.p12> | --atv-pfx-read <file> | --atv-selftest")
        }
    }

    // MARK: - Pairing

    private enum PairEvent {
        case status(TvStatus, String?)
        case saved
        case typed(String?)
    }

    private static func pair(host: String) async {
        let store = DeviceStore()
        var devices = store.loadDevices()
        let device: TvDevice
        if let known = devices.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }) {
            guard known.kind == .androidTv else {
                print("\(host) is saved as a \(known.kind.label) TV, not a Google TV.")
                return
            }
            device = known
            if !device.clientCertificate.isEmpty {
                print("\(host) is already paired; pairing again replaces the saved certificate (only if it succeeds).")
            }
        } else {
            device = TvDevice(name: TvKind.androidTv.defaultName, host: host, kind: .androidTv)
            devices.append(device)
            print("\(host) isn't saved yet; it will be added as a Google TV once paired.")
        }
        let previous = device.clientCertificate
        device.clientCertificate = "" // in memory only, so the controller pairs; saved only on success

        print("data folder: \(AppPaths.dataDir.path)")
        print("this app shows on the TV as: \(AndroidTvController.clientName)")

        let controller = AndroidTvController(device: device)
        let events = AsyncStream<PairEvent>.makeStream()
        controller.onStatusChanged = { status, message in events.continuation.yield(.status(status, message)) }
        controller.onDeviceChanged = {
            if !device.clientCertificate.isEmpty { events.continuation.yield(.saved) }
        }
        controller.onPowerStateReported = { print("power = \($0)") }

        controller.start()
        var requested = false
        var paired = false
        var deadline = Date().addingTimeInterval(200)
        let watchdog = Task.detached {
            while !Task.isCancelled, Date() < deadline { try? await Task.sleep(nanoseconds: 500_000_000) }
            events.continuation.finish()
        }

        loop: for await event in events.stream {
            switch event {
            case .status(.needsPairing, let message):
                if requested {
                    print("pairing didn't complete: \(message ?? "?")")
                    break loop
                }
                requested = true
                print("asking \(host) to show a pairing code…")
                controller.requestPairing()
            case .status(.awaitingCode, let message):
                print("The TV is showing a code. \(message ?? "")")
                print("code> ", terminator: "")
                fflush(stdout)
                DispatchQueue.global().async { events.continuation.yield(.typed(readLine())) }
            case .typed(let line):
                guard let line, !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                    print("no code entered — cancelling (the code disappears from the TV)")
                    break loop
                }
                controller.submitPairingCode(line)
            case .saved:
                paired = true
                store.saveDevices(devices)
                print("paired — certificate saved for \(host) in \(AppPaths.dataDir.path)/devices.json")
                deadline = Date().addingTimeInterval(15) // now see it connect on 6466
            case .status(.connected, _):
                print("connected on 6466 with the new certificate")
                if paired { break loop }
            case .status(let status, let message):
                print("status: \(status)\(message.map { " — \($0)" } ?? "")")
            }
        }

        watchdog.cancel()
        controller.dispose()
        if !paired { device.clientCertificate = previous }
        print(paired ? "done." : "not paired.")
    }

    // MARK: - Probe

    private static func savedCredential(host: String) -> (TvDevice, AndroidTvCredential)? {
        let devices = DeviceStore().loadDevices()
        guard let device = devices.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }),
              device.kind == .androidTv, !device.clientCertificate.isEmpty else {
            print("\(host) isn't paired yet (data folder: \(AppPaths.dataDir.path)) — run --atv-pair first")
            return nil
        }
        do {
            let credential = try AndroidTvIdentity.loadClientCertificate(device.clientCertificate)
            print("certificate loaded (TLS identity via \(credential.route.rawValue))")
            return (device, credential)
        } catch {
            print("the saved certificate can't be used: \(error.localizedDescription)")
            return nil
        }
    }

    private static func probe(host: String, seconds: Double) async {
        guard let (_, credential) = savedCredential(host: host) else { return }
        let client = AndroidTvRemoteClient()
        client.onPowerChanged = { print("  power: \($0 ? "on" : "standby")") }
        client.onPing = { print("  ping \($0)") }
        do {
            print("connecting to \(host):\(AndroidTvTlsConnection.remotePort)…")
            try await client.connect(host: host, credential: credential)
            print("connected (\(client.tlsVersion)) — vendor \"\(client.vendor)\", model \"\(client.model)\"")
            let on = try await client.waitForPowerReport(timeout: 2)
            print("reported power: \(on.map { $0 ? "on" : "standby" } ?? "not reported")")
            print("listening for \(Int(seconds)) s…")
            let runner = Task.detached { try await client.run() }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            runner.cancel()
            client.dispose()
            if case .failure(let error) = await runner.result, !(error is CancellationError) {
                print("connection ended: \(describe(error))")
            }
        } catch {
            print("failed: \(describe(error))")
            client.dispose()
        }
        print("done.")
    }

    private static func power(host: String, action: String) async {
        guard ["on", "off", "toggle"].contains(action) else { print("action must be on, off or toggle"); return }
        let devices = DeviceStore().loadDevices()
        guard let device = devices.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }),
              device.kind == .androidTv else {
            print("\(host) isn't a saved Google TV — run --atv-pair first")
            return
        }
        let controller = AndroidTvController(device: device)
        let connected = AsyncStream<Void>.makeStream()
        controller.onStatusChanged = { status, message in
            print("status: \(status)\(message.map { " — \($0)" } ?? "")")
            if status == .connected || status == .needsPairing { connected.continuation.yield(()) }
        }
        controller.onPowerStateReported = { print("power = \($0)") }
        controller.onDeviceChanged = { DeviceStore().saveDevices(devices) } // keep a learned MAC
        controller.start()

        // Up to 8 s to connect; "on" goes ahead regardless, since waking an off TV is its job.
        let waiter = Task { for await _ in connected.stream { return true }; return false }
        let timer = Task { try? await Task.sleep(nanoseconds: 8_000_000_000); connected.continuation.finish() }
        _ = await waiter.value
        timer.cancel()

        switch action {
        case "on": await controller.powerOn(); print("powerOn finished")
        case "off": print("turnOff -> \(await controller.turnOff())")
        default: await controller.togglePower(); print("togglePower finished")
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        controller.dispose()
        print("done.")
    }

    // MARK: - Unpaired certificate (how a TV says "I don't know you")

    private static func unpaired(host: String, port: UInt16, tls12: Bool) async {
        do {
            let (credential, _) = try AndroidTvIdentity.createClientCertificate()
            print("fresh certificate made (TLS identity via \(credential.route.rawValue)); connecting to \(host):\(port)\(tls12 ? " (TLS ≤ 1.2)" : "")…")
            let started = Date()
            let tls = try await AndroidTvTlsConnection.open(host: host, port: port, credential: credential,
                                                            timeout: 6, maxVersion: tls12 ? .TLSv12 : nil)
            let summary = tls.serverCertificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "none"
            print(String(format: "handshake completed after %.2f s (%@), server certificate: %@",
                         Date().timeIntervalSince(started), tls.tlsVersion, summary))
            do {
                let frame = try await tls.readFrame(timeout: 6, step: "First message")
                print(String(format: "first frame after %.2f s: %d bytes — the TV accepted the certificate",
                             Date().timeIntervalSince(started), frame.count))
            } catch {
                print(String(format: "first read failed after %.2f s: %@", Date().timeIntervalSince(started), describe(error)))
            }
            tls.close()
        } catch {
            print("connect failed: \(describe(error))")
        }
    }

    /// The error, how the controller classifies it, and Network.framework's own words.
    static func describe(_ error: Error) -> String {
        var text = error.localizedDescription
        if let atv = error as? AndroidTvError {
            if case .tls(_, let detail) = atv { text += " — Network.framework: \(detail)" }
            text += " [rejection: \(atv.isCertificateRejected ? "yes" : "no"), unreachable: \(atv.isUnreachable ? "yes" : "no")]"
        }
        return text
    }

    // MARK: - PKCS#12 files

    private static func pfxNew(path: String) {
        do {
            let (credential, base64) = try AndroidTvIdentity.createClientCertificate()
            guard let data = Data(base64Encoded: base64) else { print("internal error"); return }
            // The private key is in there unencrypted: owner-only, as --adb-key new does.
            guard FileManager.default.createFile(atPath: path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                print("failed: can't write \(path)")
                return
            }
            print("wrote \(data.count) bytes to \(path) (no password; identity via \(credential.route.rawValue))")
        } catch {
            print("failed: \(error.localizedDescription)")
        }
    }

    private static func pfxRead(path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { print("can't read \(path)"); return }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        var entries: [(label: String, bytes: Data)] = []
        if text.hasPrefix("{") || text.hasPrefix("["), let json = try? JSONSerialization.jsonObject(with: data) {
            collectCertificates(json, into: &entries)
            if entries.isEmpty { print("no ClientCertificate values in that JSON"); return }
        } else if let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters), decoded.first == 0x30 {
            entries = [("base64", decoded)]
        } else {
            entries = [("DER", data)]
        }

        for (label, bytes) in entries {
            print("\(label):")
            do {
                let contents = try Pkcs12.read(Array(bytes))
                let credential = try AndroidTvIdentity.credential(from: contents, privateKey: nil)
                let subject = SecCertificateCopySubjectSummary(credential.certificate) as String? ?? "?"
                let modulus = try AndroidTvIdentity.rsaPublicKey(credential.certificate).modulus
                print("  OK — subject \"\(subject)\", RSA \(modulus.count * 8)-bit, TLS identity via \(credential.route.rawValue)")
            } catch {
                print("  FAILED — \(error.localizedDescription)")
            }
        }
    }

    private static func collectCertificates(_ json: Any, into entries: inout [(label: String, bytes: Data)]) {
        if let object = json as? [String: Any] {
            if let value = object["ClientCertificate"] as? String, !value.isEmpty,
               let bytes = Data(base64Encoded: value, options: .ignoreUnknownCharacters) {
                let name = object["Name"] as? String ?? "?"
                let host = object["Host"] as? String ?? "?"
                entries.append(("\(name) (\(host))", bytes))
            }
            for value in object.values { collectCertificates(value, into: &entries) }
        } else if let array = json as? [Any] {
            for value in array { collectCertificates(value, into: &entries) }
        }
    }
}

// MARK: - Self-test

/// Offline checks of everything in the Google TV path that doesn't need a TV.
private enum AtvSelfTest {
    private static var passed = 0
    private static var failed = 0

    private static func check(_ name: String, _ body: () throws -> Bool) {
        let ok: Bool
        var note = ""
        do { ok = try body() } catch { ok = false; note = " (\(error.localizedDescription))" }
        if ok { passed += 1 } else { failed += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(note)")
    }

    private static func checkAsync(_ name: String, _ body: () async throws -> Bool) async {
        let ok: Bool
        var note = ""
        do { ok = try await body() } catch { ok = false; note = " (\(AtvCli.describe(error)))" }
        if ok { passed += 1 } else { failed += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(note)")
    }

    static func run(slow: Bool) async {
        protobuf()
        let made = certificates()
        pkcs12(made)
        identities(made)
        await tlsLoopback()
        await fakeTvScenario()
        await refusalCountScenario()
        if slow { await silentTvScenario() }
        print("\(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }

    // MARK: Protobuf

    private static func protobuf() {
        check("protobuf: varints round-trip (0, 127, 128, 300, 2^32, 2^64-1)") {
            let values: [UInt64] = [0, 127, 128, 300, 1 << 32, .max]
            var w = ProtoWriter()
            for (i, v) in values.enumerated() { w.varint(i + 1, v) }
            let m = try ProtoMessage.parse(w.bytes)
            return values.enumerated().allSatisfy { m.varint($0.offset + 1) == $0.element }
        }
        check("protobuf: nested message, string and bytes fields") {
            let w = ProtoWriter().withVarint(1, 2).withVarint(2, 200)
                .withMessage(10, ProtoWriter().withString(1, "atvremote").withString(2, "Mac ✓"))
                .withBytes(40, [0, 1, 255])
            let m = try ProtoMessage.parse(w.bytes)
            return m.varint(1) == 2 && m.varint(2) == 200
                && m.message(10)?.string(1) == "atvremote" && m.message(10)?.string(2) == "Mac ✓"
                && m.has(40) && m.varint(40) == nil
        }
        check("protobuf: pairing_request matches the reference encoding") {
            // Envelope {1: 2, 2: 200, 10: {1: "atvremote", 2: "x"}}
            let w = ProtoWriter().withVarint(1, 2).withVarint(2, 200)
                .withMessage(10, ProtoWriter().withString(1, "atvremote").withString(2, "x"))
            let expected: [UInt8] = [0x08, 0x02, 0x10, 0xC8, 0x01, 0x52, 0x0E,
                                     0x0A, 0x09] + Array("atvremote".utf8) + [0x12, 0x01, 0x78]
            return w.bytes == expected
        }
        check("protobuf: empty remote_start means standby (proto3 omits false)") {
            let m = try ProtoMessage.parse(ProtoWriter().withMessage(40, ProtoWriter()).bytes)
            return m.message(40) != nil && (m.message(40)?.varint(1) ?? 0) == 0
        }
        check("protobuf: fixed64/fixed32 fields are skipped") {
            let bytes: [UInt8] = [0x09, 1, 2, 3, 4, 5, 6, 7, 8, 0x15, 1, 2, 3, 4, 0x18, 0x05]
            return try ProtoMessage.parse(bytes).varint(3) == 5
        }
        check("protobuf: malformed input throws, never traps") {
            let bad: [[UInt8]] = [
                [0x08],                                     // varint missing
                [0x08, 0x80],                               // truncated varint
                [0x12, 0x05, 0x01],                         // length past the end
                [0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01], // huge length
                [0x0B],                                     // wire type 3 (group)
                [0x0E],                                     // wire type 6
                [0x09, 1, 2],                               // truncated fixed64
                [0x08] + [UInt8](repeating: 0xFF, count: 11), // varint too long
            ]
            return bad.allSatisfy { (try? ProtoMessage.parse($0)) == nil }
        }
        check("protobuf: 20 000 random buffers parse or fail cleanly") {
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<20_000 {
                let n = Int.random(in: 0...64, using: &rng)
                let bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
                if let m = try? ProtoMessage.parse(bytes) { _ = m.message(1); _ = m.string(2); _ = m.varint(3) }
            }
            return true
        }
        check("framing: frame/read round-trip, 0 and 300 bytes and the 1 MiB cap") {
            for size in [0, 1, 127, 128, 300, ProtoFraming.maxMessageBytes] {
                let body = [UInt8](repeating: 0xAB, count: size)
                let framed = ProtoFraming.frame(body)
                var pos = 0
                let sem = DispatchSemaphore(value: 0)
                var out: [UInt8]?
                Task {
                    out = try? await ProtoFraming.read(
                        nextByte: { pos += 1; return framed[pos - 1] },
                        nextBytes: { n in defer { pos += n }; return Array(framed[pos..<(pos + n)]) })
                    sem.signal()
                }
                sem.wait()
                if out != body { return false }
            }
            return true
        }
        check("framing: over-cap and over-long lengths are refused") {
            let overCap = Array(ProtoFraming.frame([UInt8](repeating: 0, count: ProtoFraming.maxMessageBytes + 1)).prefix(3))
            let overLong: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
            for bytes in [overCap, overLong] {
                var pos = 0
                let sem = DispatchSemaphore(value: 0)
                var failedCleanly = false
                Task {
                    do {
                        _ = try await ProtoFraming.read(
                            nextByte: {
                                guard pos < bytes.count else { throw ProtoError("end") }
                                pos += 1; return bytes[pos - 1]
                            },
                            nextBytes: { _ in throw ProtoError("must not allocate") })
                    } catch let error as ProtoError {
                        failedCleanly = error.message.contains("too")
                    } catch {}
                    sem.signal()
                }
                sem.wait()
                if !failedCleanly { return false }
            }
            return true
        }
    }

    // MARK: Certificates

    private struct Made {
        let contents: Pkcs12Contents
        let base64: String
        let credential: AndroidTvCredential
    }

    private static func certificates() -> Made? {
        var made: Made?
        check("certificate: generate RSA-2048 self-signed, load the saved PKCS#12 back") {
            let (credential, base64) = try AndroidTvIdentity.createClientCertificate()
            guard let data = Data(base64Encoded: base64) else { return false }
            let contents = try Pkcs12.read(Array(data))
            made = Made(contents: contents, base64: base64, credential: credential)
            return contents.certificate == credential.certificateDer
        }
        guard let made else { return nil }
        let der = made.contents.certificate

        check("certificate: macOS parses it; subject is CN=TVControlForMac") {
            guard let cert = SecCertificateCreateWithData(nil, Data(der) as CFData) else { return false }
            return (SecCertificateCopySubjectSummary(cert) as String?) == AndroidTvIdentity.subjectName
        }
        check("certificate: v3, sha256WithRSAEncryption, 2048-bit, exponent 65537") {
            let cert = try Asn1Node.parse(der).sequence(min: 3, "cert")
            let tbs = try cert[0].sequence(min: 7, "tbs")
            let version = try tbs[0].children().first?.smallInt()
            let alg = try cert[1].sequence(min: 1, "alg")[0].objectIdentifier()
            let key = try AndroidTvIdentity.rsaPublicKey(certificate: der)
            return version == 2 && alg == Oid.sha256WithRSA && key.modulus.count == 256 && key.exponent == [1, 0, 1]
        }
        check("certificate: signature verifies with its own public key") {
            let cert = try Asn1Node.parse(der).sequence(min: 3, "cert")
            let tbs = Der.tlv(cert[0].tag, Array(cert[0].content))
            let signature = Array(cert[2].content.dropFirst())
            guard let secCert = SecCertificateCreateWithData(nil, Data(der) as CFData),
                  let key = SecCertificateCopyKey(secCert) else { return false }
            return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(tbs) as CFData,
                                         Data(signature) as CFData, nil)
        }
        check("certificate: valid from yesterday, for 25 years (GeneralizedTime past 2049)") {
            let tbs = try Asn1Node.parse(der).sequence(min: 3, "cert")[0].sequence(min: 7, "tbs")
            let validity = try tbs[4].sequence(min: 2, "validity")
            let from = String(decoding: validity[0].content, as: UTF8.self)
            let to = String(decoding: validity[1].content, as: UTF8.self)
            let f = DateFormatter()
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyMMdd"
            let yesterday = f.string(from: Date().addingTimeInterval(-86_400))
            let year = Calendar(identifier: .gregorian).component(.year, from: Date()) + 25
            return validity[0].tag == 0x17 && from.hasPrefix(yesterday)
                && (year >= 2050 ? validity[1].tag == 0x18 : validity[1].tag == 0x17)
                && to.hasPrefix(year >= 2050 ? String(year) : String(year % 100))
        }
        check("pairing: client RSA key reads the same via Security and via our DER parser") {
            let a = try AndroidTvIdentity.rsaPublicKey(made.credential.certificate)
            let b = try AndroidTvIdentity.rsaPublicKey(certificate: der)
            return a.modulus == b.modulus && a.exponent == b.exponent && a.modulus.first != 0
        }
        return made
    }

    // MARK: PKCS#12

    private static func pkcs12(_ made: Made?) {
        guard let made else { return }
        check("pkcs12: writer → reader round-trip (null-password form, as .NET writes)") {
            let back = try Pkcs12.read(try Pkcs12.write(made.contents))
            return back.certificate == made.contents.certificate && back.privateKey == made.contents.privateKey
        }
        check("pkcs12: reader accepts the empty-password form (00 00, as OpenSSL writes) too") {
            let bytes = try Pkcs12.write(made.contents, bmpPassword: Pkcs12Crypto.emptyBmp)
            let back = try Pkcs12.read(bytes)
            return back.privateKey == made.contents.privateKey
        }
        check("pkcs12: a file with a real password is refused, not misread") {
            let bytes = try Pkcs12.write(made.contents, password: "secret")
            return (try? Pkcs12.read(bytes)) == nil
        }
        check("pkcs12: PKCS#12 KDF known answers (from `openssl kdf … PKCS12KDF`)") {
            func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
            let salt: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
            // The classic "smeg" vector: SHA-1, id 1, 1 iteration, 24 bytes.
            let a = try Pkcs12Crypto.pkcs12Kdf(hash: .sha1, password: Pkcs12Crypto.bmpPassword("smeg"),
                                               salt: [0x0A, 0x58, 0xCF, 0x64, 0x53, 0x0D, 0x82, 0x3F],
                                               id: 1, iterations: 1, length: 24)
            // Empty password (00 00): a SHA-1 MAC key at 2000 iterations, and a SHA-256 one at 2048.
            let b = try Pkcs12Crypto.pkcs12Kdf(hash: .sha1, password: Pkcs12Crypto.emptyBmp, salt: salt,
                                               id: 3, iterations: 2000, length: 20)
            let c = try Pkcs12Crypto.pkcs12Kdf(hash: .sha256, password: Pkcs12Crypto.emptyBmp, salt: salt,
                                               id: 3, iterations: 2048, length: 32)
            return hex(a) == "8AAAE6297B6CB04642AB5B077851284EB7128F1A2A7FBCA3"
                && hex(b) == "369C83F9B5828D859F8929A900450B74910AFDEF"
                && hex(c) == "878F85FF6DB5C92F2DA873FDB0ECAE4BDC9DCC3CB5FAF9226D10EE23AF02546A"
        }
        check("pkcs12: every truncation fails cleanly") {
            let bytes = try Pkcs12.write(made.contents)
            for n in stride(from: 0, to: bytes.count, by: 7) where (try? Pkcs12.read(Array(bytes.prefix(n)))) != nil {
                return false
            }
            return true
        }
        check("pkcs12: 400 random corruptions fail cleanly (or still decode the right key)") {
            let bytes = try Pkcs12.write(made.contents)
            for _ in 0..<400 {
                var copy = bytes
                for _ in 0..<Int.random(in: 1...4) {
                    copy[Int.random(in: 0..<copy.count)] = UInt8.random(in: 0...255)
                }
                if let back = try? Pkcs12.read(copy), back.privateKey != made.contents.privateKey { return false }
            }
            return true
        }
        check("asn1: random and deeply nested input fails cleanly") {
            for _ in 0..<5_000 {
                let bytes = (0..<Int.random(in: 0...48)).map { _ in UInt8.random(in: 0...255) }
                if let node = try? Asn1Node.parse(bytes) { _ = try? node.children(); _ = try? node.octets() }
            }
            let deep = [UInt8](repeating: 0x30, count: 2000).flatMap { [$0, UInt8(0x80)] }
            return (try? Asn1Node.parse(deep)) == nil
        }
    }

    // MARK: Identity

    private static func identities(_ made: Made?) {
        guard let made else { return }
        for route in [AndroidTvIdentity.Route.secIdentityCreate, .pkcs12MemoryImport] {
            guard AndroidTvIdentity.isAvailable(route) else {
                print("SKIP  identity via \(route.rawValue): not available on this macOS")
                continue
            }
            check("identity via \(route.rawValue): signs with the key, carries the certificate") {
                let credential = try AndroidTvIdentity.credential(from: made.contents, privateKey: nil, route: route)
                var cert: SecCertificate?
                var key: SecKey?
                guard SecIdentityCopyCertificate(credential.identity, &cert) == errSecSuccess,
                      SecIdentityCopyPrivateKey(credential.identity, &key) == errSecSuccess,
                      let cert, let key, let publicKey = SecCertificateCopyKey(cert) else { return false }
                let message = Data("pairing".utf8) as CFData
                guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message, nil) else {
                    return false
                }
                return (SecCertificateCopyData(cert) as Data) == Data(made.contents.certificate)
                    && SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message, signature, nil)
            }
        }
        check("identity: nothing was added to the keychain") {
            let query: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: AndroidTvIdentity.subjectName,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            var result: CFTypeRef?
            return SecItemCopyMatching(query as CFDictionary, &result) == errSecItemNotFound
        }
    }

    // MARK: TLS loopback

    /// A local TLS server that demands a client certificate: proves the in-memory identity
    /// is actually presented over Network.framework, and that frames make it across.
    private static func tlsLoopback() async {
        await checkAsync("tls loopback: client certificate presented, server certificate captured, frame read") {
            try await loopback(acceptClient: true)
        }
        await checkAsync("tls loopback: a server refusing the certificate surfaces as an error") {
            do {
                _ = try await loopback(acceptClient: false)
                return false
            } catch let error as AndroidTvError {
                print("      (server refused → \(AtvCli.describe(error)))")
                return true
            }
        }
        // A TLS 1.2 TV would otherwise get a resumed session on the next connection: no
        // certificates exchanged, so no server certificate for the pairing secret.
        await checkAsync("tls loopback: TLS 1.2, second connection is a full handshake (no session resumption)") {
            try await loopback(acceptClient: true, tls12: true, connections: 2)
        }
    }

    private static func loopback(acceptClient: Bool, tls12: Bool = false, connections: Int = 1) async throws -> Bool {
        let server = try AndroidTvIdentity.createClientCertificate().credential
        let client = try AndroidTvIdentity.createClientCertificate().credential
        let queue = DispatchQueue(label: "selftest.tls")
        let seen = SeenBox()

        let tls = NWProtocolTLS.Options()
        if let id = sec_identity_create(server.identity) {
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, id)
        }
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        if tls12 { sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12) }
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            seen.set(chain?.first.map { Array(SecCertificateCopyData($0) as Data) })
            complete(acceptClient)
        }, queue)
        let params = NWParameters(tls: tls)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        defer { listener.cancel() }

        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    let reply = ProtoWriter().withMessage(1, ProtoWriter().withString(1, "loopback")).bytes
                    connection.send(content: Data(ProtoFraming.frame(reply)), completion: .idempotent)
                }
            }
            connection.start(queue: queue)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.set() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let e): if once.set() { continuation.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }

        for _ in 0..<connections {
            seen.set(nil)
            let connection = try await AndroidTvTlsConnection.open(host: "127.0.0.1", port: port, credential: client, timeout: 5)
            defer { connection.close() }
            let frame = try ProtoMessage.parse(try await connection.readFrame(timeout: 5))
            let serverDer = connection.serverCertificate.map { Array(SecCertificateCopyData($0) as Data) }
            guard seen.get() == client.certificateDer,
                  serverDer == server.certificateDer,
                  frame.message(1)?.string(1) == "loopback" else { return false }
        }
        return true
    }

    private final class SeenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [UInt8]?
        func set(_ v: [UInt8]?) { lock.withLock { value = v } }
        func get() -> [UInt8]? { lock.withLock { value } }
    }

    // MARK: Fake TV

    /// The production controller against a stand-in TV on 127.0.0.1:6467/6466: pairing with
    /// code checks, the remote handshake, pings, power reports and the power toggle, a lost
    /// connection, a TV that stops reporting power, a TV that forgets us, and dispose.
    /// It checks our side of the protocol against our reading of it, not against a real TV.
    private static func fakeTvScenario() async {
        let tv: FakeTv
        do {
            tv = try await FakeTv.start()
        } catch {
            print("SKIP  fake TV: can't listen on 127.0.0.1:6466/6467 (\(error.localizedDescription))")
            return
        }
        defer { tv.stop() }

        let device = TvDevice(name: "Fake", host: "127.0.0.1", kind: .androidTv)
        var controller: AndroidTvController? = AndroidTvController(device: device)
        // Only weak references from here on, so the last check can see it freed.
        weak let c = controller
        let log = StatusLog()
        c?.onStatusChanged = { log.add($0, $1) }
        c?.onPowerStateReported = { log.power($0) }
        c?.onDeviceChanged = { log.deviceChanged() }
        c?.start()

        await checkAsync("fake TV: unpaired controller waits for the user (\"Not paired\")") {
            await log.waitFor(.needsPairing, "Not paired")
        }
        await checkAsync("fake TV: pairing request → the TV shows a code (\"Enter the code from the TV\")") {
            c?.requestPairing()
            return await log.waitFor(.awaitingCode, "Enter the code from the TV")
                && tv.clientName == AndroidTvController.clientName
        }
        await checkAsync("fake TV: malformed code is caught locally and re-prompts") {
            c?.submitPairingCode("XYZ")
            return await log.waitFor(.awaitingCode, "Codes have 6 characters, 0 to 9 and A to F")
        }
        await checkAsync("fake TV: wrong code is caught locally (never sent) and re-prompts") {
            guard let code = tv.displayedCode, let first = UInt8(code.prefix(2), radix: 16) else { return false }
            c?.submitPairingCode(String(format: "%02X", first ^ 0x01) + code.dropFirst(2))
            return await log.waitFor(.awaitingCode, "Wrong code. Try again") && !tv.secretReceived
        }
        await checkAsync("fake TV: right code (lower case, spaced) pairs; the certificate the TV saw is saved") {
            guard let code = tv.displayedCode else { return false }
            c?.submitPairingCode(code.lowercased().prefix(3) + " " + code.lowercased().dropFirst(3))
            guard await log.waitFor(.connected, timeout: 8) else { return false }
            let saved = try Pkcs12.read(Array(Data(base64Encoded: device.clientCertificate) ?? Data()))
            return saved.certificate == tv.pairedCertificate && log.deviceChanges >= 1
        }
        await checkAsync("fake TV: power report arrives (\"Active\"), pings are answered") {
            let active = await log.waitForPower("Active")
            try await Task.sleep(nanoseconds: 2_500_000_000)
            return active && tv.pongs >= 2
        }
        await checkAsync("fake TV: turnOff presses the power key once and waits for standby") {
            let ok = await c?.turnOff() ?? false
            let reported = await log.waitForPower("Standby")
            return ok && reported && tv.keys == 1 && !tv.isOn
        }
        await checkAsync("fake TV: turnOff on a TV already in standby sends no key") {
            let ok = await c?.turnOff() ?? false
            return ok && tv.keys == 1
        }
        await checkAsync("fake TV: powerOn presses the key and waits for the TV to say it's on") {
            await c?.powerOn()
            return tv.keys == 2 && tv.isOn
        }
        await checkAsync("fake TV: togglePower on a TV that's on puts it in standby") {
            await c?.togglePower()
            return tv.keys == 3 && !tv.isOn
        }
        await checkAsync("fake TV: a dropped connection → \"Reconnecting\", then back") {
            tv.reportPower = false
            tv.dropConnections()
            let lost = await log.waitFor(.disconnected, "Reconnecting")
            let back = await log.waitFor(.connected, timeout: 8)
            return lost && back
        }
        await checkAsync("fake TV: with the power state unreported, the toggle isn't sent") {
            let ok = await c?.turnOff() ?? true
            return !ok && tv.keys == 3
        }
        await checkAsync("fake TV: the TV forgets us → one retry, then \"Needs pairing again\", certificate cleared") {
            tv.rejectAll = true
            tv.dropConnections()
            let retried = await log.waitFor(.disconnected, "Reconnecting")
            let unpaired = await log.waitFor(.needsPairing, "Needs pairing again", timeout: 15)
            return retried && unpaired && device.clientCertificate.isEmpty
        }
        await checkAsync("fake TV: dispose stops the loop and frees the controller") {
            c?.dispose()
            controller = nil
            let count = log.count
            for _ in 0..<40 where c != nil { try await Task.sleep(nanoseconds: 50_000_000) }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return c == nil && log.count == count
        }

        // Dispose while the TV is showing a code: the pairing connection must close.
        let second = TvDevice(name: "Fake 2", host: "127.0.0.1", kind: .androidTv)
        var other: AndroidTvController? = AndroidTvController(device: second)
        weak let weakOther = other
        let log2 = StatusLog()
        other?.onStatusChanged = { log2.add($0, $1) }
        other?.start()
        await checkAsync("fake TV: dispose during code entry closes the pairing connection") {
            other?.requestPairing()
            guard await log2.waitFor(.awaitingCode, "Enter the code from the TV") else { return false }
            let open = tv.openPairingConnections
            other?.dispose()
            other = nil
            for _ in 0..<40 where weakOther != nil || tv.openPairingConnections >= open {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return weakOther == nil && tv.openPairingConnections < open
        }
    }

    /// Two refusals with the TV out of reach between them (one odd handshake, then days of
    /// the TV being away) mustn't add up to "Needs pairing again".
    private static func refusalCountScenario() async {
        guard let (credential, pfx) = try? AndroidTvIdentity.createClientCertificate() else { return }
        let device = TvDevice(name: "Fake", host: "127.0.0.1", kind: .androidTv)
        device.clientCertificate = pfx
        let controller = AndroidTvController(device: device)
        defer { controller.dispose() }
        let log = StatusLog()
        controller.onStatusChanged = { log.add($0, $1) }

        await checkAsync("refusals: one, then the TV out of reach, then one more keeps the pairing") {
            let first = try await FakeTv.start()
            first.trust(credential.certificateDer, on: true)
            controller.start()
            guard await log.waitFor(.connected) else { first.stop(); return false }
            first.rejectAll = true
            first.dropConnections()
            // The drop is a plain close; the reconnect after it is the first refusal.
            let dropped = await log.waitFor(.disconnected, "Reconnecting")
            let refused = await log.waitFor(.disconnected, "Reconnecting") && dropped
            first.stop() // gone from the network: the next attempts are refused at TCP
            let away = await log.waitFor(.disconnected, "Can't reach the TV", timeout: 10)

            let second = try await FakeTv.start()
            defer { second.stop() }
            second.rejectAll = true
            let refusedAgain = await log.waitFor(.disconnected, "Reconnecting", timeout: 20)
            let kept = !device.clientCertificate.isEmpty
            // Two in a row from here on do count.
            let unpaired = await log.waitFor(.needsPairing, "Needs pairing again", timeout: 20)
            return refused && away && refusedAgain && kept && unpaired && device.clientCertificate.isEmpty
        }
    }

    /// A TV that goes quiet with the connection still open (it lost power, or fell off Wi-Fi):
    /// the power key must go out once and not be pressed again blindly, and 20 s of silence
    /// must end the connection. Takes about a minute, so only with `--atv-selftest slow`.
    private static func silentTvScenario() async {
        let tv: FakeTv
        do {
            tv = try await FakeTv.start()
        } catch {
            print("SKIP  slow: can't listen on 127.0.0.1:6466/6467 (\(error.localizedDescription))")
            return
        }
        defer { tv.stop() }
        guard let (credential, pfx) = try? AndroidTvIdentity.createClientCertificate() else { return }
        tv.trust(credential.certificateDer, on: false)

        let device = TvDevice(name: "Fake", host: "127.0.0.1", kind: .androidTv)
        device.clientCertificate = pfx
        var controller: AndroidTvController? = AndroidTvController(device: device)
        weak let c = controller
        let log = StatusLog()
        c?.onStatusChanged = { log.add($0, $1) }
        c?.onPowerStateReported = { log.power($0) }
        c?.start()

        await checkAsync("slow: a paired controller connects and hears \"Standby\"") {
            let connected = await log.waitFor(.connected)
            let standby = await log.waitForPower("Standby")
            return connected && standby
        }
        await checkAsync("slow: TV gone silent → powerOn presses the key once, never blindly again, drops the connection") {
            tv.silent = true
            log.skipToEnd()
            let started = Date()
            await c?.powerOn()
            print(String(format: "      (powerOn gave up after %.1f s)", Date().timeIntervalSince(started)))
            let dropped = await log.waitFor(.disconnected, "Reconnecting", timeout: 1)
            return tv.keys == 1 && dropped
        }
        await checkAsync("slow: 20 s of silence on an open connection counts as lost") {
            // powerOn left a fresh connection behind; the TV said its hello and nothing since.
            guard c?.status == .connected, let since = log.lastTime(of: .connected) else { return false }
            log.skipToEnd()
            let lost = await log.waitFor(.disconnected, "Reconnecting", timeout: 26)
            let silence = Date().timeIntervalSince(since)
            print(String(format: "      (dropped after %.1f s of silence)", silence))
            return lost && silence >= 19.5 && silence < 23
        }
        c?.dispose()
        controller = nil
    }

    /// Everything a controller reported, for the scenario to wait on in order.
    private final class StatusLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(TvStatus, String?)] = []
        private var times: [Date] = []
        private var cursor = 0
        private var powers: [String] = []
        private var powerCursor = 0
        private var changes = 0

        var count: Int { lock.withLock { entries.count } }
        var deviceChanges: Int { lock.withLock { changes } }

        func add(_ status: TvStatus, _ message: String?) {
            lock.withLock {
                entries.append((status, message))
                times.append(Date())
            }
        }
        /// When `status` was last reported.
        func lastTime(of status: TvStatus) -> Date? {
            lock.withLock { entries.lastIndex { $0.0 == status }.map { times[$0] } }
        }
        /// Waits only for what's reported from now on.
        func skipToEnd() { lock.withLock { cursor = entries.count } }
        func power(_ state: String) { lock.withLock { powers.append(state) } }
        func deviceChanged() { lock.withLock { changes += 1 } }

        /// Waits for `status` (with `message`, if given) at or after the last match.
        func waitFor(_ status: TvStatus, _ message: String? = nil, timeout: TimeInterval = 5) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let found: Bool = lock.withLock {
                    guard let i = entries[cursor...].firstIndex(where: { $0.0 == status && (message == nil || $0.1 == message) })
                    else { return false }
                    cursor = i + 1
                    return true
                }
                if found { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }

        func waitForPower(_ state: String, timeout: TimeInterval = 5) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let found: Bool = lock.withLock {
                    guard let i = powers[powerCursor...].firstIndex(of: state) else { return false }
                    powerCursor = i + 1
                    return true
                }
                if found { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }
    }
}

/// A stand-in Google TV on 127.0.0.1: the pairing port shows (records) a code and checks the
/// secret the way a TV does; the remote port accepts only the certificate it paired with,
/// introduces itself, pings every second, reports power and toggles it on KEYCODE_POWER.
/// Diagnostics only: used by `--atv-selftest` and by `--fake-tv` (`CliFakeTv`).
final class FakeTv: @unchecked Sendable {
    private let server: AndroidTvCredential
    private let queue = DispatchQueue(label: "selftest.faketv")
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private var remoteConnections: [NWConnection] = []
    private var pairingOpen = 0

    private var lastClientCertificate: [UInt8]?
    private var code: String?
    private var expectedSecret: [UInt8]?
    private var paired: [UInt8]?
    private var name: String?
    private var gotSecret = false
    private var on = true
    private var keyCount = 0
    private var pongCount = 0
    private var reject = false
    private var report = true
    private var mute = false
    private var vendorName = "FakeVendor"
    private var modelName = "FakeModel"

    /// What the TV says about itself in the remote handshake; "TCL" makes the app offer
    /// brightness setup.
    var vendor: String {
        get { lock.withLock { vendorName } }
        set { lock.withLock { vendorName = newValue } }
    }
    var model: String {
        get { lock.withLock { modelName } }
        set { lock.withLock { modelName = newValue } }
    }

    /// Told what happens (a code shown, a key pressed, a certificate refused), for `--fake-tv`
    /// to print. Set before `start`'s listeners see traffic; called on the TV's queue.
    var onEvent: ((String) -> Void)?
    var displayedCode: String? { lock.withLock { code } }
    var pairedCertificate: [UInt8]? { lock.withLock { paired } }
    var clientName: String? { lock.withLock { name } }
    var secretReceived: Bool { lock.withLock { gotSecret } }
    var isOn: Bool { lock.withLock { on } }
    var keys: Int { lock.withLock { keyCount } }
    var pongs: Int { lock.withLock { pongCount } }
    var openPairingConnections: Int { lock.withLock { pairingOpen } }
    var rejectAll: Bool {
        get { lock.withLock { reject } }
        set { lock.withLock { reject = newValue } }
    }
    var reportPower: Bool {
        get { lock.withLock { report } }
        set { lock.withLock { report = newValue } }
    }
    /// Like a TV that lost power with the socket still open: no pings, no reports, keys ignored.
    var silent: Bool {
        get { lock.withLock { mute } }
        set { lock.withLock { mute = newValue } }
    }

    /// Accept `certificate` on the remote port as if it had paired; set the power state.
    func trust(_ certificate: [UInt8], on: Bool) {
        lock.withLock {
            paired = certificate
            self.on = on
        }
    }

    private init(server: AndroidTvCredential) {
        self.server = server
    }

    static func start() async throws -> FakeTv {
        let tv = FakeTv(server: try AndroidTvIdentity.createClientCertificate().credential)
        try await tv.listen(port: AndroidTvTlsConnection.pairingPort, remote: false)
        try await tv.listen(port: AndroidTvTlsConnection.remotePort, remote: true)
        return tv
    }

    func stop() {
        let (all, conns) = lock.withLock { (listeners, remoteConnections) }
        all.forEach { $0.cancel() }
        conns.forEach { $0.cancel() }
    }

    /// Goes to standby or comes back, and says so on every open remote connection.
    func setPower(on: Bool) {
        let conns: [NWConnection] = lock.withLock {
            self.on = on
            return remoteConnections
        }
        conns.forEach { reportPowerState($0) }
    }

    /// Forgets the paired certificate, as a TV does when its remotes are cleared, and drops
    /// the connections that used it.
    func forget() {
        lock.withLock { paired = nil }
        dropConnections()
    }

    func dropConnections() {
        let conns: [NWConnection] = lock.withLock {
            defer { remoteConnections.removeAll() }
            return remoteConnections
        }
        conns.forEach { $0.cancel() }
    }

    private func listen(port: UInt16, remote: Bool) async throws {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        if let id = sec_identity_create(server.identity) { sec_protocol_options_set_local_identity(options, id) }
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_verify_block(options, { [weak self] _, trust, complete in
            guard let self else { complete(false); return }
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            let der = chain?.first.map { Array(SecCertificateCopyData($0) as Data) }
            let accept: Bool = self.lock.withLock {
                if !remote { self.lastClientCertificate = der; return true }
                return !self.reject && der != nil && der == self.paired
            }
            if remote && !accept { self.onEvent?("refused a certificate it isn't paired with") }
            complete(accept)
        }, queue)
        let params = NWParameters(tls: tls)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            remote ? self?.serveRemote(connection) : self?.servePairing(connection)
        }
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
        lock.withLock { listeners.append(listener) }
    }

    // MARK: Pairing port

    private func servePairing(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.lock.withLock { self.pairingOpen += 1 }
            case .failed, .cancelled: self.lock.withLock { self.pairingOpen -= 1 }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection) { [weak self] message, send in
            guard let self else { return }
            var status: UInt64 = 200
            if let request = message.message(10) {
                self.lock.withLock { self.name = request.string(2) }
            } else if message.has(30) {
                self.showCode()
            } else if let secret = message.message(40)?.bytes(1) {
                status = self.lock.withLock {
                    self.gotSecret = true
                    guard secret == self.expectedSecret else { return 402 }
                    self.paired = self.lastClientCertificate
                    return 200
                }
                self.onEvent?(status == 200 ? "paired" : "wrong pairing secret")
            }
            send(ProtoWriter().withVarint(1, 2).withVarint(2, status).bytes)
        }
    }

    // What a TV does: pick two random bytes, hash both public keys with them, and display the
    // hash's first byte followed by the two bytes.
    private func showCode() {
        lock.withLock {
            guard let client = lastClientCertificate,
                  let c = try? AndroidTvIdentity.rsaPublicKey(certificate: client),
                  let s = try? AndroidTvIdentity.rsaPublicKey(certificate: server.certificateDer) else { return }
            let nonce = Pkcs12Crypto.randomBytes(2)
            let hash = HashKind.sha256.hash(c.modulus + c.exponent + s.modulus + s.exponent + nonce)
            expectedSecret = hash
            code = ([hash[0]] + nonce).map { String(format: "%02X", $0) }.joined()
        }
        if let shown = displayedCode { onEvent?("showing pairing code \(shown)") }
    }

    // MARK: Remote port

    private func serveRemote(_ connection: NWConnection) {
        lock.withLock { remoteConnections.append(connection) }
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            self.onEvent?("remote connection open")
            // remote_configure: the TV speaks first.
            let (model, vendor) = self.lock.withLock { (self.modelName, self.vendorName) }
            self.send(connection, ProtoWriter().withMessage(1, ProtoWriter()
                .withVarint(1, 622)
                .withMessage(2, ProtoWriter().withString(1, model).withString(2, vendor))).bytes)
        }
        connection.start(queue: queue)
        receive(connection) { [weak self] message, send in
            guard let self else { return }
            if self.silent {
                // Count what arrives, answer nothing.
                if message.message(10)?.varint(1) == 26 { self.lock.withLock { self.keyCount += 1 } }
                return
            }
            if message.has(1) {
                // The client's configure → remote_set_active, then the power state, then pings.
                send(ProtoWriter().withMessage(2, ProtoWriter().withVarint(1, 622)).bytes)
                self.reportPowerState(connection)
                self.ping(connection, counter: 1)
            } else if message.has(9) {
                self.lock.withLock { self.pongCount += 1 }
            } else if let key = message.message(10), key.varint(1) == 26 {
                let nowOn: Bool = self.lock.withLock {
                    self.keyCount += 1
                    self.on.toggle()
                    return self.on
                }
                self.onEvent?("power key → \(nowOn ? "on" : "standby")")
                self.queue.asyncAfter(deadline: .now() + 0.2) { self.reportPowerState(connection) }
            }
        }
    }

    private func reportPowerState(_ connection: NWConnection) {
        let (report, on, mute) = lock.withLock { (report, on, mute) }
        guard report, !mute else { return }
        // proto3 leaves out false: standby is an empty remote_start.
        let start = on ? ProtoWriter().withVarint(1, 1) : ProtoWriter()
        send(connection, ProtoWriter().withMessage(40, start).bytes)
    }

    private func ping(_ connection: NWConnection, counter: UInt64) {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, case .ready = connection.state else { return }
            if !self.silent {
                self.send(connection, ProtoWriter().withMessage(8, ProtoWriter().withVarint(1, counter)).bytes)
            }
            self.ping(connection, counter: counter + 1)
        }
    }

    // MARK: Plumbing

    private func send(_ connection: NWConnection, _ message: [UInt8]) {
        connection.send(content: Data(ProtoFraming.frame(message)), completion: .idempotent)
    }

    private func receive(_ connection: NWConnection, buffer: [UInt8] = [],
                         handler: @escaping (ProtoMessage, ([UInt8]) -> Void) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer + (data.map { Array($0) } ?? [])
            while let (frame, used) = Self.splitFrame(buffer) {
                buffer.removeFirst(used)
                if let message = try? ProtoMessage.parse(frame) {
                    handler(message) { self.send(connection, $0) }
                }
            }
            if error == nil && !complete {
                self.receive(connection, buffer: buffer, handler: handler)
            } else {
                connection.cancel() // the client went away; as a TV would, let go of it
            }
        }
    }

    private static func splitFrame(_ bytes: [UInt8]) -> ([UInt8], Int)? {
        var length = 0
        var shift = 0
        var i = 0
        while i < bytes.count, shift <= 28 {
            let b = bytes[i]
            length |= Int(b & 0x7F) << shift
            i += 1
            if b & 0x80 == 0 {
                guard bytes.count - i >= length else { return nil }
                return (Array(bytes[i..<(i + length)]), i + length)
            }
            shift += 7
        }
        return nil
    }
}
