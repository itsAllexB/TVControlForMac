// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Security

// The Android TV Remote protocol authenticates this app by a self-signed client certificate,
// on both the pairing and the remote port. The TV remembers the certificate it paired with,
// so the certificate and its key are saved with the TV (as PKCS#12, see Pkcs12.swift) and
// presented on every connection.
//
// TLS on macOS wants that as a SecIdentity, and a SecIdentity normally comes out of the
// keychain. Putting the key there would leave items behind in the user's keychain, may
// prompt, and ties access to the code signature, which changes with every ad-hoc build.
// So the identity is assembled in memory instead (see `makeIdentity`).

/// The certificate this app presents to one Google TV, ready for TLS.
final class AndroidTvCredential {
    let identity: SecIdentity
    let certificate: SecCertificate
    /// The certificate as DER, for the pairing secret and for saving.
    let certificateDer: [UInt8]
    /// How the SecIdentity was assembled, for the log.
    let route: AndroidTvIdentity.Route

    init(identity: SecIdentity, certificate: SecCertificate, certificateDer: [UInt8], route: AndroidTvIdentity.Route) {
        self.identity = identity
        self.certificate = certificate
        self.certificateDer = certificateDer
        self.route = route
    }
}

enum AndroidTvIdentity {
    /// Subject and issuer of the certificates we make. The TV shows the client name sent
    /// during pairing, not this, but it identifies the app in the TV's own records.
    static let subjectName = "TVControlForMac"

    enum Route: String {
        /// Security.framework's SecIdentityCreate: pairs an in-memory key with its certificate.
        /// Not in the public headers, but exported since Mac OS X 10.5 and used to this day.
        case secIdentityCreate = "SecIdentityCreate"
        /// SecPKCS12Import with kSecImportToMemoryOnly (macOS 15+): public API, nothing stored.
        case pkcs12MemoryImport = "SecPKCS12Import (memory only)"
    }

    // MARK: Creating and loading

    /// Creates the self-signed certificate that identifies this app to a TV, plus its PKCS#12
    /// form (base64, private key included) for persisting alongside the device.
    static func createClientCertificate() throws -> (credential: AndroidTvCredential, base64Pfx: String) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            // In memory only: the key lives in the saved PKCS#12, never in the keychain.
            kSecAttrIsPermanent as String: false,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw Pkcs12Error("Couldn't generate an RSA key: \(describe(error))")
        }
        let pkcs1 = try externalRepresentation(privateKey)
        let certificateDer = try makeSelfSignedCertificate(privateKey: privateKey)
        let contents = Pkcs12Contents(certificate: certificateDer, privateKey: pkcs1)
        let pfx = try Pkcs12.write(contents)
        return (try credential(from: contents, privateKey: privateKey), Data(pfx).base64EncodedString())
    }

    /// Loads a certificate saved by `createClientCertificate`, or by TVControlForWin.
    static func loadClientCertificate(_ base64Pfx: String) throws -> AndroidTvCredential {
        guard let data = Data(base64Encoded: base64Pfx, options: .ignoreUnknownCharacters) else {
            throw Pkcs12Error("The saved certificate isn't valid base64.")
        }
        let contents = try Pkcs12.read(Array(data))
        return try credential(from: contents, privateKey: nil)
    }

    static func credential(from contents: Pkcs12Contents, privateKey: SecKey?, route: Route? = nil) throws -> AndroidTvCredential {
        guard let certificate = SecCertificateCreateWithData(nil, Data(contents.certificate) as CFData) else {
            throw Pkcs12Error("The saved certificate can't be parsed.")
        }
        let key = try privateKey ?? makePrivateKey(pkcs1: contents.privateKey)
        let (identity, used) = try makeIdentity(certificate: certificate, privateKey: key, contents: contents, only: route)
        return AndroidTvCredential(identity: identity, certificate: certificate,
                                   certificateDer: contents.certificate, route: used)
    }

    static func makePrivateKey(pkcs1: [UInt8]) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error) else {
            throw Pkcs12Error("The saved private key can't be used: \(describe(error))")
        }
        return key
    }

    // MARK: SecIdentity

    private typealias SecIdentityCreateFunction =
        @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?

    private static let secIdentityCreate: SecIdentityCreateFunction? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_NOLOAD)
                ?? dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecIdentityCreate") else { return nil }
        return unsafeBitCast(symbol, to: SecIdentityCreateFunction.self)
    }()

    private static let routeLogged = OnceFlag()

    /// Whether `route` can be used on this Mac.
    static func isAvailable(_ route: Route) -> Bool {
        switch route {
        case .secIdentityCreate: return secIdentityCreate != nil
        case .pkcs12MemoryImport: if #available(macOS 15, *) { return true } else { return false }
        }
    }

    /// Pairs a key that exists only in memory with its certificate.
    ///
    /// SecIdentityCreate first: it does exactly that and nothing else. It's private API, so
    /// should a future macOS drop it, SecPKCS12Import with kSecImportToMemoryOnly (public since
    /// macOS 15) does the same through a throwaway PKCS#12. The keychain is never used: before
    /// macOS 15 SecPKCS12Import can only import into it, which is why it isn't a route there.
    /// `only` restricts to one route (self-test).
    static func makeIdentity(certificate: SecCertificate, privateKey: SecKey, contents: Pkcs12Contents,
                             only: Route? = nil) throws -> (SecIdentity, Route) {
        var failures: [String] = []

        if only == nil || only == .secIdentityCreate {
            if let create = secIdentityCreate {
                if let identity = create(nil, certificate, privateKey)?.takeRetainedValue() {
                    logRoute(.secIdentityCreate, failures)
                    return (identity, .secIdentityCreate)
                }
                failures.append("SecIdentityCreate returned nothing")
            } else {
                failures.append("SecIdentityCreate isn't available")
            }
        }

        if only == nil || only == .pkcs12MemoryImport {
            if #available(macOS 15, *) {
                do {
                    let identity = try importInMemory(contents)
                    logRoute(.pkcs12MemoryImport, failures)
                    return (identity, .pkcs12MemoryImport)
                } catch {
                    failures.append(error.localizedDescription)
                }
            } else {
                failures.append("SecPKCS12Import can't import to memory before macOS 15")
            }
        }

        let reason = failures.joined(separator: "; ")
        Log.write("Android TV: no way to build a TLS identity on this Mac (\(reason))")
        throw Pkcs12Error("Can't use the TV certificate on this Mac (\(reason)).")
    }

    @available(macOS 15, *)
    private static func importInMemory(_ contents: Pkcs12Contents) throws -> SecIdentity {
        // A real password, because SecPKCS12Import's handling of "no password" varies.
        let password = Pkcs12Crypto.randomBytes(16).map { String(format: "%02x", $0) }.joined()
        let pfx = try Pkcs12.write(contents, password: password)
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(Data(pfx) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw Pkcs12Error("SecPKCS12Import failed (\(status))") }
        guard let list = items as? [[String: Any]],
              let value = list.first?[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
            throw Pkcs12Error("SecPKCS12Import returned no identity")
        }
        return value as! SecIdentity // type checked just above
    }

    private static func logRoute(_ route: Route, _ failures: [String]) {
        guard routeLogged.set() else { return }
        let note = failures.isEmpty ? "" : " (\(failures.joined(separator: "; ")))"
        Log.write("Android TV: TLS identity via \(route.rawValue)\(note)")
    }

    // MARK: Certificate

    /// An X.509 v3 certificate, self-signed with sha256WithRSAEncryption: CN=TVControlForMac,
    /// valid from yesterday (so a TV whose clock is a little behind still accepts it) for 25
    /// years, no extensions. The same shape TVControlForWin's CertificateRequest produces.
    static func makeSelfSignedCertificate(privateKey: SecKey, now: Date = Date()) throws -> [UInt8] {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw Pkcs12Error("No public key for the new key.") }
        let publicPkcs1 = try externalRepresentation(publicKey)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let notBefore = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let notAfter = calendar.date(byAdding: .year, value: 25, to: now) ?? now

        // A positive, non-zero 64-bit serial, as .NET makes them.
        var serial = Pkcs12Crypto.randomBytes(8)
        serial[0] = (serial[0] & 0x7F) | 0x01

        let name = Der.sequence(Der.set(Der.sequence(Der.oid(Oid.commonName), Der.utf8(subjectName))))
        let signatureAlgorithm = Der.sequence(Der.oid(Oid.sha256WithRSA), Der.null)
        let tbs = Der.sequence(
            Der.explicit(0, Der.integer(2)), // v3
            Der.integer(unsigned: serial),
            signatureAlgorithm,
            name,
            Der.sequence(Der.time(notBefore), Der.time(notAfter)),
            name,
            Der.sequence(Der.sequence(Der.oid(Oid.rsaEncryption), Der.null), Der.bitString(publicPkcs1)))

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                    Data(tbs) as CFData, &error) as Data? else {
            throw Pkcs12Error("Couldn't sign the certificate: \(describe(error))")
        }
        return Der.sequence(tbs, signatureAlgorithm, Der.bitString(Array(signature)))
    }

    // MARK: RSA public keys (pairing secret)

    /// A certificate's RSA public key as minimal big-endian modulus and exponent.
    static func rsaPublicKey(_ certificate: SecCertificate) throws -> (modulus: [UInt8], exponent: [UInt8]) {
        // Security.framework's view first; our own parse of the certificate as the fallback,
        // for a TV certificate macOS won't make a key from.
        if let key = SecCertificateCopyKey(certificate),
           let pkcs1 = try? externalRepresentation(key),
           let parsed = try? parseRsaPublicKey(pkcs1) {
            return parsed
        }
        return try rsaPublicKey(certificate: Array(SecCertificateCopyData(certificate) as Data))
    }

    static func rsaPublicKey(certificate der: [UInt8]) throws -> (modulus: [UInt8], exponent: [UInt8]) {
        let cert = try Asn1Node.parse(der).sequence(min: 3, "Certificate")
        let tbs = try cert[0].sequence(min: 6, "TBSCertificate")
        let spkiIndex = tbs[0].tag == 0xA0 ? 6 : 5 // version is optional
        guard tbs.count > spkiIndex else { throw Pkcs12Error("Certificate without a public key.") }
        let spki = try tbs[spkiIndex].sequence(min: 2, "SubjectPublicKeyInfo")
        guard try spki[0].sequence(min: 1, "key algorithm")[0].objectIdentifier() == Oid.rsaEncryption else {
            throw Pkcs12Error("Pairing needs RSA certificates on both sides.")
        }
        let bits = try spki[1].expect(0x03, "public key BIT STRING")
        guard bits.content.first == 0 else { throw Pkcs12Error("Malformed public key BIT STRING.") }
        return try parseRsaPublicKey(Array(bits.content.dropFirst()))
    }

    /// PKCS#1 RSAPublicKey → (modulus, exponent), leading zeros stripped.
    static func parseRsaPublicKey(_ pkcs1: [UInt8]) throws -> (modulus: [UInt8], exponent: [UInt8]) {
        let parts = try Asn1Node.parse(pkcs1).sequence(min: 2, "RSAPublicKey")
        let modulus = try parts[0].unsignedIntegerBytes()
        let exponent = try parts[1].unsignedIntegerBytes()
        guard !modulus.isEmpty, !exponent.isEmpty else { throw Pkcs12Error("Empty RSA public key.") }
        return (modulus, exponent)
    }

    // MARK: Helpers

    private static func externalRepresentation(_ key: SecKey) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw Pkcs12Error("Couldn't export the key: \(describe(error))")
        }
        return Array(data)
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "unknown error" }
        return (error.takeRetainedValue() as Error).localizedDescription
    }
}
