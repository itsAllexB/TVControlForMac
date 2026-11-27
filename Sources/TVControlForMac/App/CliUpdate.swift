// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Hidden diagnostics commands for the updater. `CliMode` hands over any argument
/// listed in `commands`.
///
///   --update-check                 ask the feed, print what's there and whether it would install
///   --update-selftest              offline PASS/FAIL checks of the parts that decide things
///   --update-kind [app]            how this copy (or the given .app) can be updated, and why
///   --update-signature [app]       how this copy (or the given .app) is signed, and its requirement
///   --update-verify <zip> <ver>    unpack a release zip into staging and run every bundle check
///   --update-download              check, download, verify and test-unpack (trial runs only)
///
/// The feed is GitHub's unless a trial run (TVCONTROL_DATA_DIR) names a stand-in in
/// TVCONTROL_UPDATE_FEED, exactly as for the app.
enum UpdateCli {
    /// The first-argument flags this handles, e.g. "--example".
    static let commands: Set<String> = [
        "--update-check", "--update-selftest", "--update-kind", "--update-signature",
        "--update-verify", "--update-download",
    ]

    /// Runs the command in `args` (args[0] is the flag). Prints its own output.
    static func run(_ args: [String]) async {
        switch args.first {
        case "--update-check": await check(download: false)
        case "--update-download":
            guard AppPaths.isTrialRun else {
                print("--update-download only runs on a trial data folder: set \(AppPaths.dataDirVariable).")
                exit(2)
            }
            await check(download: true)
        case "--update-selftest": selfTest()
        case "--update-kind": kind(args.count > 1 ? args[1] : nil)
        case "--update-signature": signature(args.count > 1 ? args[1] : nil)
        case "--update-verify" where args.count >= 3: verify(zip: args[1], version: args[2])
        default: print("usage: see App/CliUpdate.swift")
        }
    }

    // MARK: - Against the feed

    private static func check(download: Bool) async {
        let setup = UpdateService.forThisCopy()
        print("running   \(AppInfo.version)")
        print("feed      \(setup.service.feed.absoluteString)\(setup.isRehearsal ? "  (rehearsal)" : "")")
        print("kind      \(setup.kind.rawValue): \(setup.reason.rawValue)")
        let latest: AppUpdate?
        do {
            latest = try await setup.service.latest()
        } catch {
            print("check     failed: \(error.localizedDescription)")
            exit(1)
        }
        guard let latest else {
            print("latest    nothing published (no release that reads as a version)")
            return
        }
        let newer = AppInfo.compareVersions(latest.version, AppInfo.version) == .orderedDescending
        print("latest    \(latest.version)  \(newer ? "newer" : "not newer")")
        print("page      \(latest.pageURL.absoluteString)")
        guard let asset = latest.asset else {
            print("file      none to install: \(latest.assetProblem ?? "?")  -> updated by hand")
            return
        }
        print("file      \(asset.name)  \(asset.size) bytes")
        print("sha256    \(asset.sha256)")
        print("url       \(asset.url.absoluteString)")
        print("validates yes (name, address, size and digest listed)")
        guard download else { return }

        do {
            let file = try await setup.service.download(latest) { _ in }
            print("download  \(file.path)  size and SHA-256 match")
            let staged = try UpdateService.stage(archive: file, version: asset.version, nextTo: Bundle.main.bundleURL)
            print("staged    \(staged.bundle.path)  passes every bundle check")
            try? FileManager.default.removeItem(at: staged.root)
        } catch {
            print("refused   \(error.localizedDescription)")
            exit(1)
        }
    }

    // MARK: - Local inspection

    private static func kind(_ path: String?) {
        let detected: (kind: InstallKind, reason: InstallKindReason)
        if let path {
            let url = URL(fileURLWithPath: path)
            detected = UpdateService.detectInstallKind(bundleURL: url, bundleIdentifier: Bundle(url: url)?.bundleIdentifier)
            print("app       \(url.standardizedFileURL.path)")
        } else {
            detected = UpdateService.detectInstallKind()
            print("app       \(Bundle.main.bundleURL.path)")
            let setup = UpdateService.forThisCopy()
            if setup.isRehearsal { print("rehearsal \(setup.kind.rawValue): \(setup.reason.rawValue)") }
        }
        print("kind      \(detected.kind.rawValue): \(detected.reason.rawValue)")
    }

    private static func signature(_ path: String?) {
        let identity = path.map { CodeSigning.identity(at: URL(fileURLWithPath: $0)) } ?? CodeSigning.running()
        guard let identity, identity.isSigned else {
            print("not signed")
            return
        }
        print("signed    \(identity.isAdHoc ? "ad hoc" : "with a certificate: \(identity.authority ?? "?")")")
        print("designated => \(identity.requirementText ?? "?")")
        if path == nil {
            print(identity.hasCertificate
                ? "updates   must satisfy the requirement above"
                : "updates   signature validity only (an ad-hoc requirement is this build's own hash)")
        }
    }

    private static func verify(zip: String, version: String) {
        let archive = URL(fileURLWithPath: zip)
        let me = CodeSigning.running()
        print("signer    \(me?.hasCertificate == true ? "must match this copy" : "not compared (this copy is ad hoc or unsigned)")")
        do {
            let staged = try UpdateService.stage(archive: archive, version: version, nextTo: archive)
            print("PASS      \(staged.bundle.lastPathComponent) \(version) passes every check")
            try? FileManager.default.removeItem(at: staged.root)
        } catch {
            print("REFUSED   \(error.localizedDescription)")
            exit(1)
        }
    }

    // MARK: - Self-test

    private static var failures = 0

    private static func expect(_ ok: Bool, _ name: String) {
        print("\(ok ? "PASS" : "FAIL")  \(name)")
        if !ok { failures += 1 }
    }

    private static func selfTest() {
        versions()
        releases()
        files()
        archives()
        installKinds()
        print(failures == 0 ? "all passed" : "\(failures) failed")
        if failures > 0 { exit(1) }
    }

    private static func versions() {
        expect(AppInfo.compareVersions("3.0.1", "3.0.0") == .orderedDescending, "3.0.1 > 3.0.0")
        expect(AppInfo.compareVersions("3.1", "3.1.0") == .orderedSame, "3.1 == 3.1.0")
        expect(AppInfo.compareVersions("v3.0.10", "3.0.9") == .orderedDescending, "3.0.10 > 3.0.9 (numeric)")
        expect(AppInfo.compareVersions("3.0.0", "3.0.1") == .orderedAscending, "3.0.0 < 3.0.1")
        expect(AppInfo.parseVersion("v3.1.0") == "3.1.0", "tag v3.1.0")
        expect(AppInfo.parseVersion(" 3.1 ") == "3.1.0", "tag 3.1 -> 3.1.0")
        expect(AppInfo.parseVersion("3.1.0-beta.2") == "3.1.0", "tag 3.1.0-beta.2 -> 3.1.0")
        expect(AppInfo.parseVersion("3.0.1.7") == "3.0.1", "tag 3.0.1.7 -> 3.0.1")
        for bad in ["3", "latest", "", "3..1", "3.x.1", "3.0.1.2.5", "+3.0"] {
            expect(AppInfo.parseVersion(bad) == nil, "tag \"\(bad)\" is not a version")
        }
        expect(UpdateService.archiveVersion("TVControlForMac-3.0.1.zip") == "3.0.1", "file name version")
        for bad in ["TVControlForMac-3.0.1.dmg", "TVControlForMac-3.0.1-arm64.zip", "Other-3.0.1.zip",
                    "TVControlForMac-.zip", "TVControlForMac-3.zip", "TVControlForMac-3.0.1.zip.exe"] {
            expect(UpdateService.archiveVersion(bad) == nil, "\(bad) is not an update file")
        }
    }

    private static let goodDigest = String(repeating: "ab", count: 32)
    private static let goodURL = "https://github.com/itsAllexB/TVControlForMac/releases/download/v3.0.1/TVControlForMac-3.0.1.zip"

    private static func asset(name: String = "TVControlForMac-3.0.1.zip", url: String? = goodURL,
                              size: Any? = 1234, digest: Any? = "sha256:" + goodDigest) -> [String: Any] {
        var entry: [String: Any] = ["name": name]
        if let url { entry["browser_download_url"] = url }
        if let size { entry["size"] = size }
        if let digest { entry["digest"] = digest }
        return entry
    }

    private static func release(tag: Any = "v3.0.1", assets: [[String: Any]] = [asset()],
                                extra: [String: Any] = [:]) -> [String: Any] {
        var release: [String: Any] = [
            "tag_name": tag, "draft": false, "prerelease": false,
            "html_url": "https://github.com/itsAllexB/TVControlForMac/releases/tag/v3.0.1", "assets": assets,
        ]
        for (key, value) in extra { release[key] = value }
        return release
    }

    private static func releases() {
        let github = DownloadTrust.gitHubReleases
        let good = UpdateService.parse(release: release(), trust: github)
        expect(good?.version == "3.0.1" && good?.asset?.name == "TVControlForMac-3.0.1.zip"
               && good?.asset?.size == 1234 && good?.asset?.sha256 == goodDigest && good?.asset?.version == "3.0.1",
               "a well-formed release is read in full")
        let upper = UpdateService.parse(release: release(assets: [asset(digest: "SHA256:" + goodDigest.uppercased())]), trust: github)
        expect(upper?.asset?.sha256 == goodDigest, "digest prefix and hex case don't matter")

        func refused(_ name: String, _ release: [String: Any]) {
            let parsed = UpdateService.parse(release: release, trust: github)
            expect(parsed != nil && parsed?.asset == nil, "\(name): nothing to install (\(parsed?.assetProblem ?? "-"))")
        }
        refused("wrong host", release(assets: [asset(url: "https://evil.example/itsAllexB/TVControlForMac/releases/download/v3.0.1/TVControlForMac-3.0.1.zip")]))
        refused("http", release(assets: [asset(url: goodURL.replacingOccurrences(of: "https:", with: "http:"))]))
        refused("other repository", release(assets: [asset(url: "https://github.com/someone/TVControlForMac/releases/download/v3.0.1/TVControlForMac-3.0.1.zip")]))
        refused("not a release download", release(assets: [asset(url: "https://github.com/itsAllexB/TVControlForMac/raw/main/TVControlForMac-3.0.1.zip")]))
        refused("dot-dot in the path", release(assets: [asset(url: "https://github.com/itsAllexB/TVControlForMac/releases/download/../../../evil/x/TVControlForMac-3.0.1.zip")]))
        refused("address names another file", release(assets: [asset(url: goodURL.replacingOccurrences(of: "TVControlForMac-3.0.1.zip", with: "payload.zip"))]))
        refused("other port", release(assets: [asset(url: goodURL.replacingOccurrences(of: "github.com", with: "github.com:8443"))]))
        refused("no address", release(assets: [asset(url: nil)]))
        refused("wrong name", release(assets: [asset(name: "TVControlForMac-3.0.1.dmg")]))
        refused("name of another version", release(assets: [asset(name: "TVControlForMac-3.0.0.zip")]))
        refused("no assets", release(assets: []))
        refused("missing digest", release(assets: [asset(digest: nil)]))
        refused("md5 digest", release(assets: [asset(digest: "md5:" + goodDigest)]))
        refused("short digest", release(assets: [asset(digest: "sha256:abcdef")]))
        refused("non-hex digest", release(assets: [asset(digest: "sha256:" + String(repeating: "zz", count: 32))]))
        refused("digest not a string", release(assets: [asset(digest: 42)]))
        refused("size zero", release(assets: [asset(size: 0)]))
        refused("size negative", release(assets: [asset(size: -5)]))
        refused("size as text", release(assets: [asset(size: "1234")]))
        refused("size as true", release(assets: [asset(size: true)]))
        refused("size too big", release(assets: [asset(size: UpdateService.maxArchiveBytes + 1)]))
        refused("first matching file decides", release(assets: [asset(digest: nil), asset()]))

        expect(UpdateService.parse(release: release(extra: ["draft": true]), trust: github) == nil, "draft is ignored")
        expect(UpdateService.parse(release: release(extra: ["prerelease": true]), trust: github) == nil, "pre-release is ignored")
        expect(UpdateService.parse(release: release(extra: ["draft": 1]), trust: github) != nil, "only JSON true marks a draft")
        expect(UpdateService.parse(release: release(tag: "nightly"), trust: github) == nil, "tag that isn't a version is ignored")
        expect(UpdateService.parse(release: release(tag: 301), trust: github) == nil, "numeric tag is ignored")
        let evilPage = UpdateService.parse(release: release(extra: ["html_url": "https://evil.example/x"]), trust: github)
        expect(evilPage?.pageURL.absoluteString == AppInfo.releasesPage, "a non-GitHub page falls back to the releases page")
        let httpPage = UpdateService.parse(release: release(extra: ["html_url": "http://github.com/x"]), trust: github)
        expect(httpPage?.pageURL.absoluteString == AppInfo.releasesPage, "an http page falls back to the releases page")
        let otherCase = release(assets: [asset(url: goodURL.replacingOccurrences(of: "itsAllexB/TVControlForMac", with: "itsallexb/tvcontrolformac"))])
        expect(UpdateService.parse(release: otherCase, trust: github)?.asset != nil, "owner and repository compare without case")

        // A rehearsal only relaxes where the file may come from: the stand-in's host and port.
        let local = DownloadTrust.sameOrigin(host: "127.0.0.1", port: 8123)
        let localAsset = asset(url: "http://127.0.0.1:8123/r/TVControlForMac-3.0.1.zip")
        expect(UpdateService.parse(release: release(assets: [localAsset]), trust: local)?.asset != nil, "rehearsal: stand-in host and port accepted")
        expect(UpdateService.parse(release: release(assets: [localAsset]), trust: github)?.asset == nil, "stand-in address refused outside a rehearsal")
        expect(UpdateService.parse(release: release(assets: [asset(url: "http://127.0.0.1:9999/TVControlForMac-3.0.1.zip")]), trust: local)?.asset == nil, "rehearsal: other port refused")
        expect(UpdateService.parse(release: release(assets: [asset(url: "http://localhost:8123/TVControlForMac-3.0.1.zip")]), trust: local)?.asset == nil, "rehearsal: other host refused")
        expect(UpdateService.parse(release: release(assets: [asset(name: "x.zip", url: "http://127.0.0.1:8123/x.zip")]), trust: local)?.asset == nil, "rehearsal: name still checked")
        expect(UpdateService.parse(release: release(assets: [asset(url: "http://127.0.0.1:8123/TVControlForMac-3.0.1.zip", digest: nil)]), trust: local)?.asset == nil, "rehearsal: digest still required")
    }

    private static func files() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tvcontrol-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("TVControlForMac-3.0.1.zip")
        try? Data("hello".utf8).write(to: file)
        let hash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        func make(size: Int64, sha: String) -> ReleaseAsset {
            ReleaseAsset(name: file.lastPathComponent, version: "3.0.1", url: URL(string: goodURL)!, size: size, sha256: sha)
        }
        expect(UpdateService.sha256(of: file) == hash, "SHA-256 of a file")
        expect(UpdateService.matches(file, make(size: 5, sha: hash)), "file with listed size and hash matches")
        expect(!UpdateService.matches(file, make(size: 6, sha: hash)), "size mismatch refused")
        expect(!UpdateService.matches(file, make(size: 5, sha: goodDigest)), "hash mismatch refused")
        expect(!UpdateService.matches(dir.appendingPathComponent("missing.zip"), make(size: 5, sha: hash)), "missing file refused")
    }

    private static func archives() {
        let app = "TVControlForMac.app"
        let plist = (name: "\(app)/Contents/Info.plist", mode: UInt32(0o100644))
        func entries(_ list: [(String, UInt32)]) -> Data {
            zip([("\(app)/", 0o040755), ("\(app)/Contents/", 0o040755), plist] + list)
        }
        func accepted(_ name: String, _ data: Data) {
            expect((try? UpdateService.checkArchive(data)) != nil, "zip: \(name) accepted")
        }
        func refused(_ name: String, _ data: Data) {
            do {
                try UpdateService.checkArchive(data)
                expect(false, "zip: \(name) refused")
            } catch {
                expect(true, "zip: \(name) refused (\(error.localizedDescription))")
            }
        }
        accepted("the app alone", entries([("\(app)/Contents/MacOS/TVControlForMac", 0o100755)]))
        accepted("ditto's __MACOSX metadata", entries([("__MACOSX/\(app)/._Contents", 0o100644)]))
        accepted("a link inside the app", entries([("\(app)/Contents/Current", 0o120755)]))
        refused("dot-dot", entries([("\(app)/../../evil", 0o100644)]))
        refused("leading dot-dot", entries([("../evil", 0o100644)]))
        refused("absolute name", entries([("/tmp/evil", 0o100644)]))
        refused("backslash", entries([("\(app)\\..\\evil", 0o100644)]))
        refused("another top-level item", entries([("Other.app/Contents/Info.plist", 0o100644)]))
        refused("a file beside the app", entries([("README.txt", 0o100644)]))
        refused("writing through a link", entries([("\(app)/Contents/link", 0o120755), ("\(app)/Contents/link/evil", 0o100644)]))
        refused("a link in __MACOSX", entries([("__MACOSX/link", 0o120755)]))
        refused("setuid file", entries([("\(app)/Contents/MacOS/TVControlForMac", 0o104755)]))
        refused("empty path part", entries([("\(app)//evil", 0o100644)]))
        refused("no Info.plist", zip([("\(app)/", 0o040755), ("\(app)/Contents/MacOS/TVControlForMac", 0o100755)]))
        refused("not a zip", Data("definitely not a zip file".utf8))
        refused("empty", Data())
        var truncated = entries([])
        truncated.removeLast(10)
        refused("truncated", truncated)
    }

    private static func installKinds() {
        func kind(_ path: String, app: Bool = true, readOnly: Bool = false, parent: Bool = true, bundle: Bool = true) -> InstallKind {
            UpdateService.classify(InstallLocation(bundlePath: path, isAppBundle: app, isReadOnlyVolume: readOnly,
                                                   parentWritable: parent, bundleWritable: bundle)).kind
        }
        expect(kind("/Applications/TVControlForMac.app") == .selfUpdating, "kind: writable /Applications copy updates itself")
        expect(kind("/Users/me/Applications/TVControlForMac.app") == .selfUpdating, "kind: ~/Applications copy updates itself")
        expect(kind("/private/var/folders/x1/abc/T/AppTranslocation/0F1E2D3C/d/TVControlForMac.app") == .manual, "kind: translocated copy is manual")
        expect(kind("/private/var/folders/x1/abc/T/AppTranslocation/0F1E/d/TVControlForMac.app", readOnly: true) == .manual, "kind: translocated read-only copy is manual")
        expect(kind("/Volumes/TVControlForMac 3.0.1/TVControlForMac.app", readOnly: true) == .manual, "kind: copy on the disk image is manual")
        expect(kind("/Applications/TVControlForMac.app", parent: false) == .manual, "kind: admin-owned /Applications is manual")
        expect(kind("/Applications/TVControlForMac.app", bundle: false) == .manual, "kind: bundle owned by someone else is manual")
        expect(kind("/Users/me/src/TVControlForMac/.build/debug", app: false) == .none, "kind: swift run is none")
        expect(kind("/Volumes/Image/TVControlForMac.app", app: false, readOnly: true) == .none, "kind: not our bundle is none")
        expect(InstallKind(rehearsalName: "selfupdating") == .selfUpdating, "TVCONTROL_INSTALL_KIND ignores case")
        expect(InstallKind(rehearsalName: "PerUser") == nil, "TVCONTROL_INSTALL_KIND rejects unknown names")
    }

    /// A zip with the given (name, unix mode) entries and no contents: just enough for the
    /// table of contents the archive checks read.
    private static func zip(_ entries: [(String, UInt32)]) -> Data {
        var local = Data(), central = Data()
        func u16(_ value: Int, into data: inout Data) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
        func u32(_ value: Int, into data: inout Data) { u16(value & 0xFFFF, into: &data); u16(value >> 16 & 0xFFFF, into: &data) }
        for (name, mode) in entries {
            let bytes = Array(name.utf8)
            let offset = local.count
            u32(0x0403_4b50, into: &local); u16(20, into: &local); u16(0x0800, into: &local); u16(0, into: &local)
            u16(0, into: &local); u16(0, into: &local); u32(0, into: &local); u32(0, into: &local); u32(0, into: &local)
            u16(bytes.count, into: &local); u16(0, into: &local); local.append(contentsOf: bytes)

            u32(0x0201_4b50, into: &central); u16(3 << 8 | 20, into: &central); u16(20, into: &central)
            u16(0x0800, into: &central); u16(0, into: &central); u16(0, into: &central); u16(0, into: &central)
            u32(0, into: &central); u32(0, into: &central); u32(0, into: &central)
            u16(bytes.count, into: &central); u16(0, into: &central); u16(0, into: &central)
            u16(0, into: &central); u16(0, into: &central); u32(Int(mode) << 16, into: &central)
            u32(offset, into: &central); central.append(contentsOf: bytes)
        }
        var end = Data()
        u32(0x0605_4b50, into: &end); u16(0, into: &end); u16(0, into: &end)
        u16(entries.count, into: &end); u16(entries.count, into: &end)
        u32(central.count, into: &end); u32(local.count, into: &end); u16(0, into: &end)
        return local + central + end
    }
}
