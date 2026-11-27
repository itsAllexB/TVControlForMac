// SPDX-License-Identifier: AGPL-3.0-or-later
import CommonCrypto
import CryptoKit
import Foundation
import Security

// A Google TV's pairing credential is saved as base64 PKCS#12 with no password, private key
// included: exactly what TVControlForWin writes with X509Certificate2.Export(Pfx) and reads
// back with a null password. Settings backups move between the two apps, so this side has
// to read what Windows (CryptoAPI) and .NET/OpenSSL write, and write something Windows reads.
//
// macOS has no API for that which fits: SecPKCS12Import is awkward with empty passwords and,
// before macOS 15, always imports into the keychain. So the format is handled here, on top of
// CommonCrypto for the ciphers and KDFs. Everything that comes from a file is bounds-checked:
// a malformed or hostile file produces an error, never a crash or an endless loop.

struct Pkcs12Error: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - ASN.1 (BER in, DER out)

/// One BER element. Content of an indefinite-length element excludes its end-of-contents marker.
struct Asn1Node {
    let tag: UInt8
    let content: ArraySlice<UInt8>

    var isConstructed: Bool { tag & 0x20 != 0 }

    static let maxDepth = 24

    /// Parses exactly one element spanning all of `bytes`.
    static func parse(_ bytes: [UInt8]) throws -> Asn1Node {
        var pos = 0
        let node = try read(bytes[...], &pos, depth: 0)
        guard pos == bytes.count else { throw Pkcs12Error("Trailing bytes after ASN.1 element.") }
        return node
    }

    /// The elements inside a constructed element.
    func children() throws -> [Asn1Node] {
        guard isConstructed else { throw Pkcs12Error("Expected a constructed ASN.1 element.") }
        var result: [Asn1Node] = []
        var pos = content.startIndex
        while pos < content.endIndex {
            result.append(try Self.read(content, &pos, depth: 1))
        }
        return result
    }

    func expect(_ tag: UInt8, _ what: String) throws -> Asn1Node {
        guard self.tag == tag else { throw Pkcs12Error("Expected \(what).") }
        return self
    }

    /// Children of a SEQUENCE, with at least `count` of them.
    func sequence(min count: Int = 0, _ what: String) throws -> [Asn1Node] {
        let items = try expect(0x30, what).children()
        guard items.count >= count else { throw Pkcs12Error("\(what) is too short.") }
        return items
    }

    /// An OCTET STRING's bytes (or an IMPLICIT-tagged one's), joining the chunks of the
    /// constructed form that BER writers may use.
    func octets(depth: Int = 0) throws -> [UInt8] {
        guard depth < Self.maxDepth else { throw Pkcs12Error("ASN.1 nested too deeply.") }
        if !isConstructed { return Array(content) }
        var out: [UInt8] = []
        for child in try children() {
            guard child.tag == 0x04 || child.tag == 0x24 else { throw Pkcs12Error("Bad OCTET STRING chunk.") }
            out += try child.octets(depth: depth + 1)
        }
        return out
    }

    func objectIdentifier() throws -> String {
        guard tag == 0x06, !content.isEmpty else { throw Pkcs12Error("Expected an OBJECT IDENTIFIER.") }
        var arcs: [UInt64] = []
        var value: UInt64 = 0
        var bits = 0
        for b in content {
            value = (value << 7) | UInt64(b & 0x7F)
            bits += 7
            guard bits <= 63 else { throw Pkcs12Error("OBJECT IDENTIFIER arc too large.") }
            if b & 0x80 == 0 {
                if arcs.isEmpty {
                    let first = min(value / 40, 2)
                    arcs.append(first)
                    arcs.append(value - first * 40)
                } else {
                    arcs.append(value)
                }
                value = 0
                bits = 0
            }
        }
        guard bits == 0 else { throw Pkcs12Error("Truncated OBJECT IDENTIFIER.") }
        return arcs.map(String.init).joined(separator: ".")
    }

    /// A small non-negative INTEGER (iteration counts, versions, key lengths).
    func smallInt() throws -> Int {
        guard tag == 0x02, !content.isEmpty, content.count <= 8,
              let first = content.first, first & 0x80 == 0 else {
            throw Pkcs12Error("Expected a small non-negative INTEGER.")
        }
        var value = 0
        for b in content {
            guard value <= (Int.max >> 8) else { throw Pkcs12Error("INTEGER too large.") }
            value = (value << 8) | Int(b)
        }
        return value
    }

    /// An INTEGER as unsigned big-endian bytes with no leading zeros (RSA modulus/exponent).
    func unsignedIntegerBytes() throws -> [UInt8] {
        guard tag == 0x02, !content.isEmpty else { throw Pkcs12Error("Expected an INTEGER.") }
        return Array(content.drop { $0 == 0 })
    }

    private static func read(_ bytes: ArraySlice<UInt8>, _ pos: inout Int, depth: Int) throws -> Asn1Node {
        guard depth < maxDepth else { throw Pkcs12Error("ASN.1 nested too deeply.") }
        guard pos < bytes.endIndex else { throw Pkcs12Error("Truncated ASN.1 element.") }
        let tag = bytes[pos]
        // Multi-byte tags never appear in anything we read.
        guard tag & 0x1F != 0x1F else { throw Pkcs12Error("Unsupported ASN.1 tag.") }
        pos += 1
        guard pos < bytes.endIndex else { throw Pkcs12Error("Truncated ASN.1 length.") }
        let first = bytes[pos]
        pos += 1

        if first == 0x80 {
            // Indefinite length (BER): only legal for constructed elements; runs to 00 00.
            guard tag & 0x20 != 0 else { throw Pkcs12Error("Indefinite length on a primitive element.") }
            let start = pos
            while true {
                guard pos + 1 < bytes.endIndex else { throw Pkcs12Error("Missing end-of-contents.") }
                if bytes[pos] == 0 && bytes[pos + 1] == 0 { break }
                _ = try read(bytes, &pos, depth: depth + 1)
            }
            let node = Asn1Node(tag: tag, content: bytes[start..<pos])
            pos += 2
            return node
        }

        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count >= 1, count <= 4 else { throw Pkcs12Error("Unsupported ASN.1 length.") }
            guard count <= bytes.endIndex - pos else { throw Pkcs12Error("Truncated ASN.1 length.") }
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[pos])
                pos += 1
            }
        }
        guard length <= bytes.endIndex - pos else { throw Pkcs12Error("ASN.1 length runs past the data.") }
        let node = Asn1Node(tag: tag, content: bytes[pos..<(pos + length)])
        pos += length
        return node
    }
}

/// DER encoders for the handful of types the certificate and PKCS#12 writers need.
enum Der {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out = [tag]
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var lenBytes: [UInt8] = []
            var v = n
            while v > 0 { lenBytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            out.append(0x80 | UInt8(lenBytes.count))
            out += lenBytes
        }
        return out + content
    }

    static func sequence(_ items: [UInt8]...) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func set(_ items: [UInt8]...) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    static func octets(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }
    static func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0] + bytes) }
    static func utf8(_ s: String) -> [UInt8] { tlv(0x0C, Array(s.utf8)) }
    static let null: [UInt8] = [0x05, 0x00]

    /// [n] EXPLICIT wrapper.
    static func explicit(_ n: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | n, content) }

    static func integer(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        repeat { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 } while v > 0
        return integer(unsigned: bytes)
    }

    /// An INTEGER from unsigned big-endian bytes (a zero byte is added when the top bit is set).
    static func integer(unsigned bytes: [UInt8]) -> [UInt8] {
        var b = Array(bytes.drop { $0 == 0 })
        if b.isEmpty { b = [0] }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
        guard arcs.count >= 2 else { return tlv(0x06, []) }
        var body = base128(arcs[0] * 40 + arcs[1])
        for arc in arcs.dropFirst(2) { body += base128(arc) }
        return tlv(0x06, body)
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        var out = [UInt8(value & 0x7F)]
        var v = value >> 7
        while v > 0 {
            out.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return out
    }

    /// X.509 Time: UTCTime through 2049, GeneralizedTime from 2050 (RFC 5280 §4.1.2.5).
    static func time(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 2000
        let rest = String(format: "%02d%02d%02d%02d%02dZ", c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        if year < 2050 {
            return tlv(0x17, Array((String(format: "%02d", year % 100) + rest).utf8))
        }
        return tlv(0x18, Array((String(format: "%04d", year) + rest).utf8))
    }
}

enum Oid {
    static let rsaEncryption = "1.2.840.113549.1.1.1"
    static let sha256WithRSA = "1.2.840.113549.1.1.11"
    static let commonName = "2.5.4.3"

    static let data = "1.2.840.113549.1.7.1"
    static let encryptedData = "1.2.840.113549.1.7.6"

    static let keyBag = "1.2.840.113549.1.12.10.1.1"
    static let shroudedKeyBag = "1.2.840.113549.1.12.10.1.2"
    static let certBag = "1.2.840.113549.1.12.10.1.3"
    static let safeContentsBag = "1.2.840.113549.1.12.10.1.6"
    static let x509Certificate = "1.2.840.113549.1.9.22.1"
    static let localKeyId = "1.2.840.113549.1.9.21"

    static let pbeSha1Rc4_128 = "1.2.840.113549.1.12.1.1"
    static let pbeSha1Rc4_40 = "1.2.840.113549.1.12.1.2"
    static let pbeSha1TripleDes = "1.2.840.113549.1.12.1.3"
    static let pbeSha1TwoKeyTripleDes = "1.2.840.113549.1.12.1.4"
    static let pbeSha1Rc2_128 = "1.2.840.113549.1.12.1.5"
    static let pbeSha1Rc2_40 = "1.2.840.113549.1.12.1.6"

    static let pbes2 = "1.2.840.113549.1.5.13"
    static let pbkdf2 = "1.2.840.113549.1.5.12"
    static let hmacSha1 = "1.2.840.113549.2.7"
    static let hmacSha224 = "1.2.840.113549.2.8"
    static let hmacSha256 = "1.2.840.113549.2.9"
    static let hmacSha384 = "1.2.840.113549.2.10"
    static let hmacSha512 = "1.2.840.113549.2.11"
    static let aes128Cbc = "2.16.840.1.101.3.4.1.2"
    static let aes192Cbc = "2.16.840.1.101.3.4.1.22"
    static let aes256Cbc = "2.16.840.1.101.3.4.1.42"
    static let desEde3Cbc = "1.2.840.113549.3.7"

    static let sha1 = "1.3.14.3.2.26"
    static let sha256 = "2.16.840.1.101.3.4.2.1"
    static let sha384 = "2.16.840.1.101.3.4.2.2"
    static let sha512 = "2.16.840.1.101.3.4.2.3"
}

// MARK: - Hashes, ciphers, KDFs

enum HashKind {
    case sha1, sha256, sha384, sha512

    var outputSize: Int {
        switch self { case .sha1: 20; case .sha256: 32; case .sha384: 48; case .sha512: 64 }
    }

    /// Block size, the "v" of the PKCS#12 KDF.
    var blockSize: Int {
        switch self { case .sha1, .sha256: 64; case .sha384, .sha512: 128 }
    }

    func hash(_ data: [UInt8]) -> [UInt8] {
        switch self {
        case .sha1: Array(Insecure.SHA1.hash(data: data))
        case .sha256: Array(SHA256.hash(data: data))
        case .sha384: Array(SHA384.hash(data: data))
        case .sha512: Array(SHA512.hash(data: data))
        }
    }

    func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let k = SymmetricKey(data: key)
        switch self {
        case .sha1: return Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: k))
        case .sha256: return Array(HMAC<SHA256>.authenticationCode(for: data, using: k))
        case .sha384: return Array(HMAC<SHA384>.authenticationCode(for: data, using: k))
        case .sha512: return Array(HMAC<SHA512>.authenticationCode(for: data, using: k))
        }
    }

    var pbkdf2Prf: CCPseudoRandomAlgorithm {
        switch self {
        case .sha1: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        case .sha256: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        case .sha384: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
        case .sha512: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
        }
    }

    static func fromDigestOid(_ oid: String) -> HashKind? {
        switch oid {
        case Oid.sha1: .sha1
        case Oid.sha256: .sha256
        case Oid.sha384: .sha384
        case Oid.sha512: .sha512
        default: nil
        }
    }

    static func fromHmacOid(_ oid: String) -> HashKind? {
        switch oid {
        case Oid.hmacSha1: .sha1
        case Oid.hmacSha256: .sha256
        case Oid.hmacSha384: .sha384
        case Oid.hmacSha512: .sha512
        default: nil
        }
    }
}

enum Pkcs12Crypto {
    /// Higher counts than any real writer uses (OpenSSL 2048, .NET/Windows 2000, modern
    /// PBKDF2 defaults up to 600 000) would only come from a file meant to hang us.
    static let maxIterations = 1_000_000

    /// The password forms the PKCS#12 KDF can mean by "no password". The KDF takes the
    /// password as a NUL-terminated BMPString, so an empty password is the two bytes 00 00,
    /// while a null one is no bytes at all; writers differ in which they use for "none".
    static let emptyBmp: [UInt8] = [0, 0]
    static let nullBmp: [UInt8] = []

    static func bmpPassword(_ password: String) -> [UInt8] {
        var out: [UInt8] = []
        for unit in password.utf16 { out += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        return out + [0, 0]
    }

    /// RFC 7292 appendix B.2. `id` is 1 for a key, 2 for an IV, 3 for a MAC key.
    static func pkcs12Kdf(hash: HashKind, password: [UInt8], salt: [UInt8], id: UInt8,
                          iterations: Int, length: Int) throws -> [UInt8] {
        guard iterations >= 1, iterations <= maxIterations else { throw Pkcs12Error("Unreasonable iteration count.") }
        let u = hash.outputSize
        let v = hash.blockSize
        let d = [UInt8](repeating: id, count: v)

        func stretch(_ x: [UInt8]) -> [UInt8] {
            guard !x.isEmpty else { return [] }
            let n = v * ((x.count + v - 1) / v)
            return (0..<n).map { x[$0 % x.count] }
        }

        var i = stretch(salt) + stretch(password)
        var out: [UInt8] = []
        while out.count < length {
            var a = hash.hash(d + i)
            for _ in 1..<iterations { a = hash.hash(a) }
            out += a
            if out.count >= length || i.isEmpty { break }
            // I_j = (I_j + B + 1) mod 2^(8v), for each v-byte block of I.
            let b = (0..<v).map { a[$0 % u] }
            for j in stride(from: 0, to: i.count, by: v) {
                var carry: UInt16 = 1
                for k in (0..<v).reversed() {
                    let sum = UInt16(i[j + k]) + UInt16(b[k]) + carry
                    i[j + k] = UInt8(sum & 0xFF)
                    carry = sum >> 8
                }
            }
        }
        while out.count < length { out += hash.hash(out) } // only when both salt and password are empty
        return Array(out.prefix(length))
    }

    static func pbkdf2(hash: HashKind, password: [UInt8], salt: [UInt8], iterations: Int, length: Int) throws -> [UInt8] {
        guard iterations >= 1, iterations <= maxIterations else { throw Pkcs12Error("Unreasonable iteration count.") }
        guard length > 0, length <= 64 else { throw Pkcs12Error("Unreasonable key length.") }
        var out = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBufferPointer { pw in
            pw.withMemoryRebound(to: Int8.self) { pw8 in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw8.baseAddress, pw.count,
                                     salt, salt.count, hash.pbkdf2Prf, UInt32(iterations), &out, length)
            }
        }
        guard status == kCCSuccess else { throw Pkcs12Error("PBKDF2 failed (\(status)).") }
        return out
    }

    /// One-shot CBC (or stream) cipher with PKCS#7 padding. A wrong key on decrypt usually
    /// surfaces here as a padding error.
    static func crypt(encrypt: Bool, algorithm: CCAlgorithm, key: [UInt8], iv: [UInt8]?, data: [UInt8],
                      padding: Bool = true) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + 32)
        var moved = 0
        let options = CCOptions(padding ? kCCOptionPKCS7Padding : 0)
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), algorithm, options,
                             key, key.count, iv, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw Pkcs12Error("Cipher failed (\(status)).") }
        return Array(out.prefix(moved))
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &out) != errSecSuccess {
            // Practically unreachable; fall back to the system CSPRNG directly.
            arc4random_buf(&out, count)
        }
        return out
    }
}

// MARK: - PKCS#12

/// What a PKCS#12 file holds that we care about: one certificate and its RSA private key.
struct Pkcs12Contents {
    /// X.509 certificate, DER.
    let certificate: [UInt8]
    /// RSA private key, PKCS#1 `RSAPrivateKey` DER (the form `SecKeyCreateWithData` takes).
    let privateKey: [UInt8]
}

enum Pkcs12 {
    // Matches what Windows / .NET write by default.
    static let writeIterations = 2000

    // MARK: Writer

    /// Writes a PKCS#12 file in the legacy profile every Windows release reads:
    /// key in a PBE-SHA1-3DES shrouded key bag, certificate in a PBE-SHA1-3DES encrypted
    /// bag, HMAC-SHA1 integrity, 2000 iterations.
    ///
    /// With `password` nil, "no password" is the null form (no password bytes at all), not
    /// the empty BMPString (00 00) that `openssl pkcs12 -passout pass:` uses. That's what
    /// .NET writes for `Export(Pfx)` with no password (checked: its MAC verifies only with
    /// the null form), so it's the form TVControlForWin's own files have and the one its
    /// loader certainly accepts. OpenSSL, .NET and our reader all try both forms anyway.
    ///
    /// Why legacy rather than PBES2/AES: TVControlForWin reads the credential with
    /// `new X509Certificate2(bytes, null, …)`, which on .NET 8 hands the bytes to Windows'
    /// own PFXImportCertStore. That reads 3DES/SHA-1 on every Windows version (it's what
    /// Windows itself writes by default), while AES-256/SHA-256 PFX only arrived with
    /// Windows 10 1709 / Server 2019. The credential guards one TV pairing, not a secret
    /// worth more than that, and it has no password anyway: the cipher adds nothing here.
    static func write(_ contents: Pkcs12Contents, password: String? = nil) throws -> [UInt8] {
        try write(contents, bmpPassword: password.map(Pkcs12Crypto.bmpPassword) ?? Pkcs12Crypto.nullBmp)
    }

    /// As `write`, with the KDF password bytes given directly (the self-test uses this to
    /// make the empty-BMPString form OpenSSL writes).
    static func write(_ contents: Pkcs12Contents, bmpPassword pw: [UInt8]) throws -> [UInt8] {
        let localKeyId = Insecure.SHA1.hash(data: contents.certificate).map { $0 }
        let attributes = Der.set(Der.sequence(Der.oid(Oid.localKeyId), Der.set(Der.octets(localKeyId))))

        // Key: PKCS#8 PrivateKeyInfo, encrypted.
        let pkcs8 = Der.sequence(Der.integer(0),
                                 Der.sequence(Der.oid(Oid.rsaEncryption), Der.null),
                                 Der.octets(contents.privateKey))
        let (keyAlg, encryptedKey) = try pbeEncrypt(pkcs8, password: pw)
        let keyBag = Der.sequence(Der.oid(Oid.shroudedKeyBag),
                                  Der.explicit(0, Der.sequence(keyAlg, Der.octets(encryptedKey))),
                                  attributes)
        let keyInfo = Der.sequence(Der.oid(Oid.data),
                                   Der.explicit(0, Der.octets(Der.sequence(keyBag))))

        // Certificate: a plain cert bag inside an encrypted SafeContents.
        let certBag = Der.sequence(Der.oid(Oid.certBag),
                                   Der.explicit(0, Der.sequence(Der.oid(Oid.x509Certificate),
                                                                Der.explicit(0, Der.octets(contents.certificate)))),
                                   attributes)
        let (certAlg, encryptedCerts) = try pbeEncrypt(Der.sequence(certBag), password: pw)
        let encryptedData = Der.sequence(Der.integer(0),
                                         Der.sequence(Der.oid(Oid.data), certAlg, Der.tlv(0x80, encryptedCerts)))
        let certInfo = Der.sequence(Der.oid(Oid.encryptedData), Der.explicit(0, encryptedData))

        let authSafe = Der.sequence(certInfo, keyInfo)

        let macSalt = Pkcs12Crypto.randomBytes(8)
        let macKey = try Pkcs12Crypto.pkcs12Kdf(hash: .sha1, password: pw, salt: macSalt, id: 3,
                                                iterations: writeIterations, length: 20)
        let mac = HashKind.sha1.hmac(key: macKey, data: authSafe)
        let macData = Der.sequence(Der.sequence(Der.sequence(Der.oid(Oid.sha1), Der.null), Der.octets(mac)),
                                   Der.octets(macSalt),
                                   Der.integer(writeIterations))

        return Der.sequence(Der.integer(3),
                            Der.sequence(Der.oid(Oid.data), Der.explicit(0, Der.octets(authSafe))),
                            macData)
    }

    private static func pbeEncrypt(_ plain: [UInt8], password: [UInt8]) throws -> (algorithm: [UInt8], cipher: [UInt8]) {
        let salt = Pkcs12Crypto.randomBytes(8)
        let key = try Pkcs12Crypto.pkcs12Kdf(hash: .sha1, password: password, salt: salt, id: 1,
                                             iterations: writeIterations, length: 24)
        let iv = try Pkcs12Crypto.pkcs12Kdf(hash: .sha1, password: password, salt: salt, id: 2,
                                            iterations: writeIterations, length: 8)
        let cipher = try Pkcs12Crypto.crypt(encrypt: true, algorithm: CCAlgorithm(kCCAlgorithm3DES),
                                            key: key, iv: iv, data: plain)
        let algorithm = Der.sequence(Der.oid(Oid.pbeSha1TripleDes),
                                     Der.sequence(Der.octets(salt), Der.integer(writeIterations)))
        return (algorithm, cipher)
    }

    // MARK: Reader

    /// Reads a password-less PKCS#12 file: legacy PBE (SHA-1 with 3DES, 2-key 3DES, RC2 or RC4),
    /// PBES2 (PBKDF2 with AES or 3DES), HMAC-SHA1/2 integrity, BER or DER.
    static func read(_ bytes: [UInt8]) throws -> Pkcs12Contents {
        let pfx = try Asn1Node.parse(bytes).sequence(min: 2, "PFX")
        guard try pfx[0].smallInt() == 3 else { throw Pkcs12Error("Unsupported PKCS#12 version.") }

        let authSafeInfo = try pfx[1].sequence(min: 2, "authSafe ContentInfo")
        guard try authSafeInfo[0].objectIdentifier() == Oid.data else {
            throw Pkcs12Error("PKCS#12 with public-key integrity isn't supported.")
        }
        let authSafeBytes = try explicitContent(authSafeInfo[1]).octets()

        // Which "no password" form the writer used: settled by the MAC when there is one.
        var candidates = [Pkcs12Crypto.emptyBmp, Pkcs12Crypto.nullBmp]
        if pfx.count >= 3 {
            guard let matched = try candidates.first(where: { try verifyMac(pfx[2], data: authSafeBytes, password: $0) }) else {
                throw Pkcs12Error("PKCS#12 integrity check failed: it has a password, or is damaged.")
            }
            candidates = [matched] + candidates.filter { $0 != matched }
        }

        var keys: [(key: [UInt8], keyId: [UInt8]?)] = []
        var certs: [(cert: [UInt8], keyId: [UInt8]?)] = []

        for info in try Asn1Node.parse(authSafeBytes).sequence("AuthenticatedSafe") {
            let parts = try info.sequence(min: 2, "ContentInfo")
            let safeContents: [UInt8]
            switch try parts[0].objectIdentifier() {
            case Oid.data:
                safeContents = try explicitContent(parts[1]).octets()
            case Oid.encryptedData:
                let encrypted = try explicitContent(parts[1]).sequence(min: 2, "EncryptedData")
                let eci = try encrypted[1].sequence(min: 3, "EncryptedContentInfo")
                guard eci[2].tag == 0x80 || eci[2].tag == 0xA0 else { throw Pkcs12Error("Missing encrypted content.") }
                safeContents = try decrypt(algorithm: eci[1], data: try eci[2].octets(), candidates: &candidates)
            default:
                throw Pkcs12Error("PKCS#12 with public-key encryption isn't supported.")
            }
            try collectBags(safeContents, depth: 0, candidates: &candidates, keys: &keys, certs: &certs)
        }

        guard !keys.isEmpty else { throw Pkcs12Error("The PKCS#12 holds no private key.") }
        guard !certs.isEmpty else { throw Pkcs12Error("The PKCS#12 holds no certificate.") }

        // Pair the key with its certificate: by public key first, then by localKeyId.
        for key in keys {
            guard let modulus = try? rsaModulus(privateKey: key.key) else { continue }
            if let cert = certs.first(where: { (try? AndroidTvIdentity.rsaPublicKey(certificate: $0.cert).modulus) == modulus }) {
                return Pkcs12Contents(certificate: cert.cert, privateKey: key.key)
            }
        }
        if let key = keys.first, let id = key.keyId, let cert = certs.first(where: { $0.keyId == id }) {
            return Pkcs12Contents(certificate: cert.cert, privateKey: key.key)
        }
        throw Pkcs12Error("The PKCS#12's private key doesn't match its certificate.")
    }

    /// The single element inside an [0] EXPLICIT wrapper.
    private static func explicitContent(_ node: Asn1Node) throws -> Asn1Node {
        guard node.tag == 0xA0, let inner = try node.children().first else { throw Pkcs12Error("Missing [0] content.") }
        return inner
    }

    private static func verifyMac(_ macDataNode: Asn1Node, data: [UInt8], password: [UInt8]) throws -> Bool {
        let macData = try macDataNode.sequence(min: 2, "MacData")
        let digestInfo = try macData[0].sequence(min: 2, "DigestInfo")
        let algorithm = try digestInfo[0].sequence(min: 1, "digest algorithm")
        let oid = try algorithm[0].objectIdentifier()
        guard let hash = HashKind.fromDigestOid(oid) else { throw Pkcs12Error("Unsupported PKCS#12 MAC (\(oid)).") }
        let expected = try digestInfo[1].expect(0x04, "MAC digest").octets()
        let salt = try macData[1].expect(0x04, "MAC salt").octets()
        let iterations = macData.count >= 3 ? try macData[2].smallInt() : 1
        let key = try Pkcs12Crypto.pkcs12Kdf(hash: hash, password: password, salt: salt, id: 3,
                                             iterations: iterations, length: hash.outputSize)
        return hash.hmac(key: key, data: data) == expected
    }

    private static func collectBags(_ safeContents: [UInt8], depth: Int, candidates: inout [[UInt8]],
                                    keys: inout [(key: [UInt8], keyId: [UInt8]?)],
                                    certs: inout [(cert: [UInt8], keyId: [UInt8]?)]) throws {
        guard depth < 4 else { throw Pkcs12Error("PKCS#12 bags nested too deeply.") }
        for bagNode in try Asn1Node.parse(safeContents).sequence("SafeContents") {
            let bag = try bagNode.sequence(min: 2, "SafeBag")
            let value = try explicitContent(bag[1])
            let keyId = bag.count >= 3 ? localKeyId(bag[2]) : nil

            switch try bag[0].objectIdentifier() {
            case Oid.keyBag:
                keys.append((try privateKey(fromPkcs8: value), keyId))
            case Oid.shroudedKeyBag:
                let epki = try value.sequence(min: 2, "EncryptedPrivateKeyInfo")
                let plain = try decrypt(algorithm: epki[0], data: try epki[1].expect(0x04, "encrypted key").octets(),
                                        candidates: &candidates)
                keys.append((try privateKey(fromPkcs8: try Asn1Node.parse(plain)), keyId))
            case Oid.certBag:
                let certBag = try value.sequence(min: 2, "CertBag")
                guard try certBag[0].objectIdentifier() == Oid.x509Certificate else { continue }
                certs.append((try explicitContent(certBag[1]).expect(0x04, "certificate").octets(), keyId))
            case Oid.safeContentsBag:
                try collectBags(Array(Der.tlv(value.tag, Array(value.content))), depth: depth + 1,
                                candidates: &candidates, keys: &keys, certs: &certs)
            default:
                continue // CRL and secret bags: nothing we need
            }
        }
    }

    private static func localKeyId(_ attributes: Asn1Node) -> [UInt8]? {
        guard attributes.tag == 0x31, let list = try? attributes.children() else { return nil }
        for attribute in list {
            guard let parts = try? attribute.sequence(min: 2, "attribute"),
                  (try? parts[0].objectIdentifier()) == Oid.localKeyId,
                  let value = try? parts[1].children().first else { continue }
            return try? value.octets()
        }
        return nil
    }

    /// PKCS#8 PrivateKeyInfo → PKCS#1 RSAPrivateKey.
    private static func privateKey(fromPkcs8 node: Asn1Node) throws -> [UInt8] {
        let info = try node.sequence(min: 3, "PrivateKeyInfo")
        let algorithm = try info[1].sequence(min: 1, "key algorithm")
        guard try algorithm[0].objectIdentifier() == Oid.rsaEncryption else {
            throw Pkcs12Error("The PKCS#12 key isn't RSA.")
        }
        let key = try info[2].expect(0x04, "private key").octets()
        _ = try rsaModulus(privateKey: key) // must parse as RSAPrivateKey
        return key
    }

    static func rsaModulus(privateKey: [UInt8]) throws -> [UInt8] {
        let parts = try Asn1Node.parse(privateKey).sequence(min: 9, "RSAPrivateKey")
        return try parts[1].unsignedIntegerBytes()
    }

    /// Decrypts with whichever "no password" form works, remembering it for the next bag.
    /// A wrong key is caught by the padding check, and then by requiring the plaintext to be
    /// one well-formed DER element, so a 1-in-256 padding fluke can't pass as success.
    private static func decrypt(algorithm: Asn1Node, data: [UInt8], candidates: inout [[UInt8]]) throws -> [UInt8] {
        var lastError: Error = Pkcs12Error("Couldn't decrypt the PKCS#12.")
        for (index, password) in candidates.enumerated() {
            do {
                let plain = try pbeDecrypt(algorithm: algorithm, data: data, bmpPassword: password)
                _ = try Asn1Node.parse(plain)
                if index != 0 { candidates.swapAt(0, index) }
                return plain
            } catch let error as Pkcs12Error where error.message.hasPrefix("Unsupported") {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func pbeDecrypt(algorithm: Asn1Node, data: [UInt8], bmpPassword: [UInt8]) throws -> [UInt8] {
        let alg = try algorithm.sequence(min: 1, "encryption algorithm")
        let oid = try alg[0].objectIdentifier()

        if oid == Oid.pbes2 {
            guard alg.count >= 2 else { throw Pkcs12Error("PBES2 without parameters.") }
            // PBES2 takes the password as plain bytes (UTF-8), so "none" is simply empty here.
            return try pbes2Decrypt(params: alg[1], data: data)
        }

        let cipher: (algorithm: CCAlgorithm, keyLength: Int, ivLength: Int)
        var twoKey = false
        switch oid {
        case Oid.pbeSha1TripleDes: cipher = (CCAlgorithm(kCCAlgorithm3DES), 24, 8)
        case Oid.pbeSha1TwoKeyTripleDes: cipher = (CCAlgorithm(kCCAlgorithm3DES), 16, 8); twoKey = true
        case Oid.pbeSha1Rc2_128: cipher = (CCAlgorithm(kCCAlgorithmRC2), 16, 8)
        case Oid.pbeSha1Rc2_40: cipher = (CCAlgorithm(kCCAlgorithmRC2), 5, 8)
        case Oid.pbeSha1Rc4_128: cipher = (CCAlgorithm(kCCAlgorithmRC4), 16, 0)
        case Oid.pbeSha1Rc4_40: cipher = (CCAlgorithm(kCCAlgorithmRC4), 5, 0)
        default: throw Pkcs12Error("Unsupported PKCS#12 encryption (\(oid)).")
        }
        guard alg.count >= 2 else { throw Pkcs12Error("PBE without parameters.") }
        let params = try alg[1].sequence(min: 2, "PBE parameters")
        let salt = try params[0].expect(0x04, "PBE salt").octets()
        let iterations = try params[1].smallInt()

        var key = try Pkcs12Crypto.pkcs12Kdf(hash: .sha1, password: bmpPassword, salt: salt, id: 1,
                                             iterations: iterations, length: cipher.keyLength)
        if twoKey { key += key.prefix(8) } // 2-key 3DES is K1 K2 K1
        let iv = cipher.ivLength > 0
            ? try Pkcs12Crypto.pkcs12Kdf(hash: .sha1, password: bmpPassword, salt: salt, id: 2,
                                         iterations: iterations, length: cipher.ivLength)
            : nil
        let isStream = cipher.algorithm == CCAlgorithm(kCCAlgorithmRC4)
        return try Pkcs12Crypto.crypt(encrypt: false, algorithm: cipher.algorithm, key: key, iv: iv,
                                      data: data, padding: !isStream)
    }

    private static func pbes2Decrypt(params: Asn1Node, data: [UInt8]) throws -> [UInt8] {
        let p = try params.sequence(min: 2, "PBES2 parameters")
        let kdf = try p[0].sequence(min: 2, "PBES2 KDF")
        guard try kdf[0].objectIdentifier() == Oid.pbkdf2 else { throw Pkcs12Error("Unsupported PBES2 KDF.") }
        let kdfParams = try kdf[1].sequence(min: 2, "PBKDF2 parameters")
        let salt = try kdfParams[0].expect(0x04, "PBKDF2 salt").octets()
        let iterations = try kdfParams[1].smallInt()
        var keyLength: Int?
        var prf = HashKind.sha1
        for extra in kdfParams.dropFirst(2) {
            if extra.tag == 0x02 {
                keyLength = try extra.smallInt()
            } else if extra.tag == 0x30 {
                let prfOid = try extra.sequence(min: 1, "PBKDF2 PRF")[0].objectIdentifier()
                guard let kind = HashKind.fromHmacOid(prfOid) else { throw Pkcs12Error("Unsupported PBKDF2 PRF (\(prfOid)).") }
                prf = kind
            }
        }

        let scheme = try p[1].sequence(min: 2, "PBES2 cipher")
        let cipherOid = try scheme[0].objectIdentifier()
        let iv = try scheme[1].expect(0x04, "PBES2 IV").octets()
        let cipher: (algorithm: CCAlgorithm, keyLength: Int, ivLength: Int)
        switch cipherOid {
        case Oid.aes128Cbc: cipher = (CCAlgorithm(kCCAlgorithmAES), 16, 16)
        case Oid.aes192Cbc: cipher = (CCAlgorithm(kCCAlgorithmAES), 24, 16)
        case Oid.aes256Cbc: cipher = (CCAlgorithm(kCCAlgorithmAES), 32, 16)
        case Oid.desEde3Cbc: cipher = (CCAlgorithm(kCCAlgorithm3DES), 24, 8)
        default: throw Pkcs12Error("Unsupported PBES2 cipher (\(cipherOid)).")
        }
        guard iv.count == cipher.ivLength else { throw Pkcs12Error("PBES2 IV has the wrong length.") }
        if let keyLength, keyLength != cipher.keyLength { throw Pkcs12Error("PBES2 key length mismatch.") }

        let key = try Pkcs12Crypto.pbkdf2(hash: prf, password: [], salt: salt, iterations: iterations,
                                          length: cipher.keyLength)
        return try Pkcs12Crypto.crypt(encrypt: false, algorithm: cipher.algorithm, key: key, iv: iv, data: data)
    }
}
