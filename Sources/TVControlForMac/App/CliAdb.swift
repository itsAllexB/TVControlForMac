// SPDX-License-Identifier: AGPL-3.0-or-later
import CryptoKit
import Foundation
import Security

/// Hidden diagnostics commands for ADB brightness. `CliMode` hands over any argument
/// listed in `commands`.
///
///   TVControlForMac --adb-setup <host>              connect, ask the TV for approval if needed
///                                                   (up to 90 s), probe, print state and value;
///                                                   the key is saved on that TV in devices.json
///   TVControlForMac --adb-get <host>                read the backlight with the stored key
///   TVControlForMac --adb-set <host> <0-100>        set it (read back) with the stored key
///   TVControlForMac --adb-shell <host> <command…>   run one shell command with the stored key
///   TVControlForMac --adb-selftest                  offline checks, PASS/FAIL per check
///   TVControlForMac --adb-key new <out.der>         write a fresh key (DER PKCS#8)
///   TVControlForMac --adb-key pub <keyfile>         print the key's ADB public-key line
///   TVControlForMac --adb-key roundtrip <keyfile>   import and re-export; is it byte-identical?
///   TVControlForMac --adb-key sign <keyfile> <token> <sig-out>   sign a 20-byte AUTH token
///
/// A key file may be DER or PEM, PKCS#8 or PKCS#1, or the base64 stored in devices.json.
///
/// For development only, `TVCONTROL_ADB_KEYFILE` makes get/set/shell use that key file
/// instead of the stored key. That key is only held in memory: nothing is saved, not even a
/// MAC address learned with it.
enum AdbCli {
    /// The first-argument flags this handles.
    static let commands: Set<String> = [
        "--adb-setup", "--adb-get", "--adb-set", "--adb-shell", "--adb-selftest", "--adb-key",
    ]

    static let keyFileVariable = "TVCONTROL_ADB_KEYFILE"

    /// Runs the command in `args` (args[0] is the flag). Prints its own output.
    static func run(_ args: [String]) async {
        let logStart = logSize()
        switch args.first {
        case "--adb-setup" where args.count >= 2:
            await setUp(host: args[1])
        case "--adb-get" where args.count >= 2:
            await getOrSet(host: args[1], value: nil)
        case "--adb-set" where args.count >= 3:
            guard let value = Int(args[2]), (0...100).contains(value) else { return usage() }
            await getOrSet(host: args[1], value: value)
        case "--adb-shell" where args.count >= 3:
            await shell(host: args[1], command: args.dropFirst(2).joined(separator: " "))
        case "--adb-selftest":
            let passed = selfTest()
            printLog(since: logStart)
            exit(passed ? 0 : 1)
        case "--adb-key":
            keyTool(Array(args.dropFirst()))
        default:
            usage()
        }
        printLog(since: logStart)
    }

    private static func usage() {
        print("""
        usage: --adb-setup <host> | --adb-get <host> | --adb-set <host> <0-100>
               --adb-shell <host> <command…> | --adb-selftest
               --adb-key new <out.der> | pub <keyfile> | roundtrip <keyfile> | sign <keyfile> <token> <sig-out>
        """)
    }

    // MARK: - Against a TV

    private static func setUp(host: String) async {
        let store = DeviceStore()
        var devices = store.loadDevices()
        let device: TvDevice
        if let known = devices.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }) {
            device = known
        } else {
            device = TvDevice(name: TvKind.androidTv.defaultName, host: host, kind: .androidTv)
            devices.append(device)
        }
        // The app saves a new key only once the TV approves it. Here it's saved up front, so
        // every run offers the same key: if someone approves it on the TV between runs, the
        // next run goes straight through instead of asking again with a new one.
        if device.adbKey.isEmpty {
            do { device.adbKey = try AdbClient.createKey() }
            catch { print("error: \(error.localizedDescription)"); return }
        }
        store.saveDevices(devices)
        print("key: \(AdbBrightness.keyName), stored on \(device.host) in \(DeviceStore.directory.path)")

        let brightness = AdbBrightness(device: device, deviceChanged: { store.saveDevices(devices) },
                                       tvIsOn: { true })
        brightness.onStateChanged = { [weak brightness] in
            guard let state = brightness?.state else { return }
            switch state {
            case .awaitingApproval:
                print("state: awaitingApproval — public key offered; accept \"Allow USB debugging?\" on the TV (up to 90 s)")
            default:
                print("state: \(state)")
            }
        }
        brightness.onReported = { print("brightness = \($0)") }

        print("setting up \(host)…")
        await brightness.setUp()
        print("result: \(brightness.state)  mac = \(device.macAddress.isEmpty ? "(unknown)" : device.macAddress)")
        brightness.dispose()
        store.saveDevices(devices)
    }

    private static func getOrSet(host: String, value: Int?) async {
        guard let (device, save) = deviceWithKey(host: host) else { return }

        let latest = LatestValue()
        let brightness = AdbBrightness(device: device, deviceChanged: save, tvIsOn: { true })
        brightness.onStateChanged = { [weak brightness] in
            if let state = brightness?.state { print("state: \(state)") }
        }
        brightness.onReported = { latest.set($0); print("brightness = \($0)") }

        await brightness.resume(mightSupport: true)
        guard brightness.state == .ready else {
            print("result: \(brightness.state) — brightness not available")
            brightness.dispose()
            return
        }

        if let value {
            print("setting \(value) (was \(latest.get().map(String.init) ?? "?"))…")
            brightness.set(value)
            await brightness.flushNow() // the first write of a connection is read back
            print("after write: \(brightness.state)")
            if brightness.state == .ready {
                // Read back over a connection of its own: what the TV says now, not anything
                // the service reported to keep a slider in sync.
                let readBack = await readBacklight(host: host, key: device.adbKey)
                print("read back = \(readBack.map(String.init) ?? "?")  \(readBack == value ? "OK" : "MISMATCH")")
            }
        }
        print("mac = \(device.macAddress.isEmpty ? "(unknown)" : device.macAddress)")
        brightness.dispose()
    }

    private static func readBacklight(host: String, key: String) async -> Int? {
        let client = AdbClient()
        defer { client.dispose() }
        do {
            try await client.connect(host: host, keyBase64: key, keyName: AdbBrightness.keyName,
                                     onApprovalNeeded: nil, approvalTimeout: 0)
            return try await AdbTclBacklight.get(client, until: .now() + 3)
        } catch {
            print("read back failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func shell(host: String, command: String) async {
        guard let (device, _) = deviceWithKey(host: host) else { return }
        let client = AdbClient()
        do {
            try await client.connect(host: host, keyBase64: device.adbKey, keyName: AdbBrightness.keyName,
                                     onApprovalNeeded: nil, approvalTimeout: 0)
            let output = try await client.shell(command, until: .now() + 10)
            print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
        } catch {
            print("error: \(error.localizedDescription)")
        }
        client.dispose()
    }

    /// The TV with its approved key: the stored one, or the development key file. Returns the
    /// device and how to persist it (a no-op for the key file, which is never saved).
    private static func deviceWithKey(host: String) -> (TvDevice, () -> Void)? {
        if let path = ProcessInfo.processInfo.environment[keyFileVariable], !path.isEmpty {
            do {
                let device = TvDevice(name: "adb test", host: host, kind: .androidTv)
                device.adbKey = try Data(loadKey(path: path)).base64EncodedString()
                print("using the key in \(keyFileVariable) (not saved)")
                return (device, {})
            } catch {
                print("error: \(error.localizedDescription)")
                return nil
            }
        }

        let store = DeviceStore()
        let devices = store.loadDevices()
        guard let device = devices.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }),
              !device.adbKey.isEmpty else {
            print("no ADB key stored for \(host) — run --adb-setup first")
            return nil
        }
        return (device, { store.saveDevices(devices) })
    }

    // MARK: - Key files

    private static func keyTool(_ args: [String]) {
        do {
            switch (args.first, args.count) {
            case ("new", 2):
                let der = Data(base64Encoded: try AdbClient.createKey()) ?? Data()
                FileManager.default.createFile(atPath: args[1], contents: der,
                                               attributes: [.posixPermissions: 0o600])
                print("wrote \(der.count) bytes to \(args[1])")

            case ("pub", 2):
                let key = try AdbKey.importPrivateKey(pkcs8: try loadKey(path: args[1]))
                print(try AdbKey.encodePublicKey(key) + " " + AdbBrightness.keyName)

            case ("roundtrip", 2):
                let original = try loadKey(path: args[1])
                let again = try AdbKey.exportPkcs8(try AdbKey.importPrivateKey(pkcs8: original))
                print(again == original ? "identical (\(original.count) bytes)" : "DIFFERS (\(original.count) → \(again.count) bytes)")

            case ("sign", 4):
                let key = try AdbKey.importPrivateKey(pkcs8: try loadKey(path: args[1]))
                let token = try [UInt8](Data(contentsOf: URL(fileURLWithPath: args[2])))
                let signature = try AdbKey.sign(token: token, with: key)
                try Data(signature).write(to: URL(fileURLWithPath: args[3]))
                print("wrote \(signature.count)-byte signature to \(args[3])")

            default:
                usage()
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }

    /// A key file's contents as PKCS#8 DER: DER or PEM, PKCS#8 or PKCS#1 (wrapped on the
    /// way in), or a bare base64 line as stored in devices.json.
    static func loadKey(path: String) throws -> [UInt8] {
        let data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        var der = [UInt8](data)
        var isPkcs1 = false
        if let text = String(data: data, encoding: .utf8), !text.isEmpty, data.first != 0x30 {
            isPkcs1 = text.contains("BEGIN RSA PRIVATE KEY")
            let body = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
            guard let decoded = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else {
                throw AdbKeyError.malformed("not DER, PEM or base64")
            }
            der = [UInt8](decoded)
        }
        return isPkcs1 ? AdbKey.wrapPkcs8(pkcs1: der) : der
    }

    // MARK: - Self-test

    /// Offline checks of everything that can be checked without a TV.
    private static func selfTest() -> Bool {
        var failures = 0
        func check(_ name: String, _ body: () throws -> Bool) {
            let passed: Bool
            var note = ""
            do { passed = try body() } catch { passed = false; note = "  (\(error.localizedDescription))" }
            if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL")  \(name)\(note)")
        }

        // PKCS#8

        var keyBase64 = ""
        var key: SecKey?
        check("PKCS#8: a new key is RSA-2048 and re-exports byte-identical") {
            keyBase64 = try AdbClient.createKey()
            guard let der = Data(base64Encoded: keyBase64) else { return false }
            let imported = try AdbKey.importPrivateKey(pkcs8: [UInt8](der))
            key = imported
            let (modulus, exponent) = try AdbKey.publicComponents(imported)
            return try AdbKey.exportPkcs8(imported) == [UInt8](der) && modulus.count == 256 && exponent == 65537
        }

        check("PKCS#8: envelope is what .NET writes (version 0, rsaEncryption, NULL)") {
            guard let der = Data(base64Encoded: keyBase64) else { return false }
            // 30 82 xx xx | 02 01 00 | 30 0d 06 09 2a864886f70d010101 05 00 | 04 82 …
            let prefix: [UInt8] = [0x02, 0x01, 0x00, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
                                   0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x04, 0x82]
            return [UInt8](der).count > 24 && Array([UInt8](der)[4..<24]) == prefix
        }

        check("PKCS#8: damaged input is an error, not a crash") {
            guard let der = Data(base64Encoded: keyBase64).map({ [UInt8]($0) }), der.count > 30 else { return false }
            var wrongOid = der
            wrongOid[15] ^= 0x01
            var badLength = der
            badLength[1] = 0x84
            var cases: [[UInt8]] = [[], [0x30], [0x30, 0x80], Array(der.prefix(der.count / 2)), der + [0],
                                    wrongOid, badLength, [0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF]]
            for cut in stride(from: 1, to: 40, by: 3) { cases.append(Array(der.prefix(cut))) }
            for bytes in cases where (try? AdbKey.importPrivateKey(pkcs8: bytes)) != nil { return false }
            return (try? AdbKey.importPrivateKey(base64: "not base64!")) == nil
        }

        // Signature

        check("AUTH: signature over a 20-byte token verifies; a different token doesn't") {
            guard let key, let publicKey = SecKeyCopyPublicKey(key) else { return false }
            var token = [UInt8](repeating: 0, count: 20)
            _ = SecRandomCopyBytes(kSecRandomDefault, token.count, &token)
            let signature = try AdbKey.sign(token: token, with: key)
            func verifies(_ message: [UInt8]) -> Bool {
                SecKeyVerifySignature(publicKey, .rsaSignatureDigestPKCS1v15SHA1, Data(message) as CFData,
                                      Data(signature) as CFData, nil)
            }
            var other = token
            other[0] ^= 0xFF
            return signature.count == 256 && verifies(token) && !verifies(other)
        }

        check("AUTH: a token that isn't 20 bytes is refused") {
            guard let key else { return false }
            return (try? AdbKey.sign(token: [UInt8](repeating: 1, count: 19), with: key)) == nil
        }

        // Public-key struct

        check("Public key: struct layout (524 bytes, 64 words, exponent last)") {
            guard let key else { return false }
            let (modulus, _) = try AdbKey.publicComponents(key)
            let blob = try AdbKey.publicKeyStruct(modulus: modulus, exponent: 65537)
            return blob.count == 524 && Array(blob[0..<4]) == [64, 0, 0, 0]
                && Array(blob[8..<264]) == modulus.reversed() && Array(blob[520..<524]) == [1, 0, 1, 0]
        }

        check("Public key: n0inv · n ≡ −1 (mod 2³²)") {
            guard let key else { return false }
            let n = try AdbKey.limbs(modulus: try AdbKey.publicComponents(key).modulus)
            return AdbKey.n0inv(n[0]) &* n[0] == UInt32.max
        }

        // Montgomery-reducing rr once must give R mod n, which for a 2048-bit n is simply
        // 2²⁰⁴⁸ − n. That's an independent route to the same number, and it's exactly the
        // arithmetic the TV performs with these two values.
        check("Public key: Montgomery(rr) = 2²⁰⁴⁸ − n") {
            guard let key else { return false }
            let n = try AdbKey.limbs(modulus: try AdbKey.publicComponents(key).modulus)
            let reduced = montgomeryReduce(AdbKey.montgomeryRR(n), n: n, n0inv: AdbKey.n0inv(n[0]))
            var expected = [UInt32](repeating: 0, count: n.count)
            AdbKey.subtract(&expected, n)
            return reduced == expected
        }

        // A throwaway test key's modulus, and the SHA-256 of what `adb pubkey` printed for it.
        check("Public key: matches adb's own output for a reference key") {
            let modulusBase64 = """
                q6nwIEeAhxY+CO4YM80NXnRhcAJ/ZoMhqMIdMjawH+UvOLrN66ryeJlRZHw2UgMC326FmFM15EH55Ti1IkkS5T3U8tF8cjuMX042BBWrI50G\
                YAyVdrY9I3Wv7GLrkgPr0tegoZwxRrDIEWpjZRi66iTpn78Ykkra2p53JcV0lc8dvJv9vRuZO2nw6dVnUs+jeJo3LAxaESWDURavQDDFX77H\
                /LO01yKymmKGfC4YoE/iNLUUX90aaG8DTtLcBRj0Y2wGEF2mDl9AdAvcvHYbzWpGPaPvtQmgz0itt3tE5oQ9ZuIl/7jcBhLVNlhn9JPFJ9yh\
                B5OV2Ydq5ARhP/LDVw==
                """
            guard let modulus = Data(base64Encoded: modulusBase64) else { return false }
            let blob = try AdbKey.publicKeyStruct(modulus: [UInt8](modulus), exponent: 65537)
            let digest = SHA256.hash(data: Data(blob)).map { String(format: "%02x", $0) }.joined()
            return digest == "2a41ae0df23a1c1a46de1333c65528aaed1d9ecd614e94b47842b463f8ec9657"
        }

        // Framing

        check("Framing: CNXN header matches the protocol byte for byte") {
            let frame = AdbClient.frame(AdbClient.cmdConnect, AdbClient.protocolVersion, AdbClient.maxPayload,
                                        Array("host::\0".utf8))
            // "CNXN", version 0x01000000, maxdata 4096, length 7, checksum 0x232, magic ~CNXN
            let header: [UInt8] = [0x43, 0x4E, 0x58, 0x4E, 0x00, 0x00, 0x00, 0x01, 0x00, 0x10, 0x00, 0x00,
                                   0x07, 0x00, 0x00, 0x00, 0x32, 0x02, 0x00, 0x00, 0xBC, 0xB1, 0xA7, 0xB1]
            return frame == header + Array("host::\0".utf8)
        }

        check("Framing: header round-trips; bad magic and oversized payloads are refused") {
            let payload = [UInt8](repeating: 0xFF, count: 300)
            let frame = AdbClient.frame(AdbClient.cmdWrite, 7, 9, payload)
            let header = try AdbClient.parseHeader(Array(frame[0..<24]))
            guard header == AdbClient.Header(command: AdbClient.cmdWrite, arg0: 7, arg1: 9, length: 300,
                                             checksum: 300 * 255) else { return false }
            var badMagic = Array(frame[0..<24])
            badMagic[20] ^= 1
            var huge = Array(frame[0..<24])
            huge[15] = 0x10 // 256 MiB
            return (try? AdbClient.parseHeader(badMagic)) == nil && (try? AdbClient.parseHeader(huge)) == nil
                && (try? AdbClient.parseHeader(Array(frame[0..<23]))) == nil
        }

        // Parsing what the TV prints

        check("Parcel: values, exception codes and junk") {
            AdbTclBacklight.parseInt("Result: Parcel(00000000 0000003c   '....<...')") == 60
                && AdbTclBacklight.parseInt("Result: Parcel(00000000 00000001   '........')") == 1
                && AdbTclBacklight.parseInt("Result: Parcel(00000000 ffffffff   '........')") == -1
                && AdbTclBacklight.parseInt("Result: Parcel(ffffffec 00000000 '....')") == nil
                && AdbTclBacklight.parseInt("service: Service tcl_tv_display does not exist") == nil
                && AdbTclBacklight.parseInt("") == nil
        }

        check("MAC: parsed, upper-cased, invalid ones dropped") {
            AdbBrightness.parseMacs("d4:12:43:aa:bb:0c\n00:00:00:00:00:00\n") == ["D4:12:43:AA:BB:0C"]
                && AdbBrightness.parseMacs("a0:b1:c2:d3:e4:f5\n10:20:30:40:50:60\n")
                    == ["A0:B1:C2:D3:E4:F5", "10:20:30:40:50:60"]
                && AdbBrightness.parseMacs("ff:ff:ff:ff:ff:ff\n01:00:5e:00:00:01\n").isEmpty
                && AdbBrightness.parseMacs("cat: /sys/class/net/eth0/address: No such file or directory").isEmpty
                && AdbBrightness.parseMacs("a0:b1:c2:d3:e4:f5:06\n").isEmpty
                && AdbBrightness.parseMacs("    link/ether 7c:2a:db:10:20:30 brd ff:ff:ff:ff:ff:ff\n")
                    == ["7C:2A:DB:10:20:30"]
        }

        print(failures == 0 ? "all checks passed" : "\(failures) check(s) FAILED")
        return failures == 0
    }

    /// a · R⁻¹ mod n (R = 2^(32·count)), the textbook word-by-word Montgomery reduction.
    /// Written separately from the encoder so the self-test doesn't check it against itself.
    private static func montgomeryReduce(_ a: [UInt32], n: [UInt32], n0inv: UInt32) -> [UInt32] {
        let count = n.count
        var t = [UInt32](repeating: 0, count: 2 * count + 2)
        for i in 0..<count { t[i] = a[i] }
        for i in 0..<count {
            let m = t[i] &* n0inv // makes the low word vanish
            var carry: UInt64 = 0
            for j in 0..<count {
                let sum = UInt64(t[i + j]) + UInt64(m) * UInt64(n[j]) + carry
                t[i + j] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            var k = i + count
            while carry != 0, k < t.count {
                let sum = UInt64(t[k]) + carry
                t[k] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
                k += 1
            }
        }
        var result = Array(t[count..<(2 * count)])
        if t[2 * count] != 0 || !AdbKey.isLess(result, n) { AdbKey.subtract(&result, n) }
        return result
    }

    // MARK: - Log echo

    // The services report through the app log; show what this run added to it.
    private static var logURL: URL { AppPaths.dataDir.appendingPathComponent("log.txt") }

    private static func logSize() -> Int {
        (try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func printLog(since offset: Int) {
        guard let data = try? Data(contentsOf: logURL) else { return }
        let start = data.count >= offset ? offset : 0 // the log was reset while we ran
        for line in String(decoding: data.dropFirst(start), as: UTF8.self).split(separator: "\n") {
            print("  log: \(line)")
        }
    }
}

/// The last value a callback reported, readable from another thread.
private final class LatestValue: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?

    func set(_ newValue: Int?) {
        lock.lock(); value = newValue; lock.unlock()
    }

    func get() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
