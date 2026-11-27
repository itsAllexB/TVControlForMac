// SPDX-License-Identifier: AGPL-3.0-or-later
import CryptoKit
import Darwin
import Foundation
import Security

/// How this copy of the app is placed on the Mac, which decides how it can be updated.
/// The Mac's version of TVControlForWin's PerUser / PerMachine / Portable.
enum InstallKind: String, Sendable, CaseIterable {
    /// A real app bundle this user can replace where it is: an update is downloaded,
    /// checked and swapped in, by itself while the window is closed if that's switched on.
    case selfUpdating = "SelfUpdating"

    /// An app bundle that can't be replaced in place (run from the disk image, moved
    /// into a temporary place by macOS, or in a folder this user can't change). An update
    /// means downloading the new version by hand.
    case manual = "Manual"

    /// Not running from an app bundle at all (`swift run`, the diagnostics CLI): there's
    /// nothing to update.
    case none = "None"

    /// A name from TVCONTROL_INSTALL_KIND, ignoring case.
    init?(rehearsalName: String?) {
        guard let name = rehearsalName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        guard let kind = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        self = kind
    }
}

/// Why `UpdateService.detectInstallKind` decided what it did.
enum InstallKindReason: String, Sendable {
    case notABundle = "not running from the app bundle"
    case translocated = "macOS is running it from a temporary copy (App Translocation)"
    case readOnlyVolume = "it is on a read-only volume, such as the disk image"
    case notWritable = "this user can't replace the app or the folder it is in"
    case replaceable = "the app bundle can be replaced in place"
    case forced = "set by TVCONTROL_INSTALL_KIND for a rehearsal"
}

/// The facts install-kind detection works from, kept apart so the decision can be tested
/// on sample paths without touching the disk.
struct InstallLocation: Equatable, Sendable {
    var bundlePath: String
    /// A `.app` bundle whose identifier is this app's.
    var isAppBundle: Bool
    var isReadOnlyVolume: Bool
    /// Moving the bundle out and the new one in needs the folder it's in to be writable,
    /// and moving a folder to another parent needs the folder itself to be writable too.
    var parentWritable: Bool
    var bundleWritable: Bool
}

/// The file in a release that the updater installs.
struct ReleaseAsset: Equatable, Sendable {
    let name: String
    /// The version as written in the file name. The app inside must say exactly this.
    let version: String
    let url: URL
    let size: Int64
    /// Lowercase hex, as GitHub lists it in the asset's `digest`.
    let sha256: String
}

/// A published release, as far as updating is concerned.
struct AppUpdate: Equatable, Sendable {
    /// Three parts, e.g. "3.0.1".
    let version: String
    /// The release's page, for downloading by hand. Always a GitHub web address.
    let pageURL: URL
    /// The zipped app to install, or nil when the release has none this app can verify
    /// (then `pageURL` is the only way).
    let asset: ReleaseAsset?
    /// Why `asset` is nil, for the log and the diagnostics CLI.
    let assetProblem: String?
}

/// Which download addresses are acceptable.
enum DownloadTrust: Equatable, Sendable {
    /// The repository's GitHub release downloads, over HTTPS.
    case gitHubReleases
    /// A rehearsal's stand-in server: same host and port as the stand-in feed. This is all
    /// TVControlForWin relaxes for a rehearsal, and all that's relaxed here.
    case sameOrigin(host: String, port: Int)

    /// True when `url` is somewhere this release file may come from. The address must also
    /// end in the file's own name, so a release can't point its zip at some other file.
    func allows(_ url: URL, name: String) -> Bool {
        guard url.lastPathComponent == name, url.query == nil, url.user == nil else { return false }
        switch self {
        case .gitHubReleases:
            guard url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "github.com",
                  url.port == nil || url.port == 443 else { return false }
            let prefix = String(AppInfo.releaseDownloadPrefix.dropFirst("https://github.com".count))
            let path = url.path
            return path.lowercased().hasPrefix(prefix.lowercased()) && !path.contains("/../")
        case let .sameOrigin(host, port):
            return url.host?.lowercased() == host && DownloadTrust.effectivePort(url) == port
        }
    }

    static func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}

/// Something that stopped an update. The message goes to the log; the UI shows its own
/// short wording.
struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A verified new app bundle, unpacked next to (on the same volume as) the running one.
struct StagedUpdate: Sendable {
    /// The staging folder. Everything in it goes once the swap is done.
    let root: URL
    let bundle: URL
    let version: String
}

/// Finds, downloads, checks and installs app updates. Releases are published on GitHub;
/// "the latest release" there is the newest one that isn't a draft or pre-release.
///
/// What gets installed is an app downloaded from the internet, so it is held to what GitHub
/// says about it before anything on disk changes: the file has exactly the expected name,
/// comes from the repository's release downloads over HTTPS, and matches the size and
/// SHA-256 GitHub lists for it. A release without a listed hash is treated as having nothing
/// to install. Then the unpacked app has to be this app, at exactly that version, with a
/// valid signature, from the same signer as the running copy when that copy has a real
/// certificate.
struct UpdateService: Sendable {
    static let feedVariable = "TVCONTROL_UPDATE_FEED"
    static let installKindVariable = "TVCONTROL_INSTALL_KIND"
    /// Rehearsals only: make one step of the swap helper fail on purpose ("move-aside",
    /// "move-new", "verify" or "launch"), to see the old version come back.
    static let helperFailVariable = "TVCONTROL_UPDATE_HELPER_FAIL"

    static let maxArchiveBytes: Int64 = 400 * 1024 * 1024
    private static let maxFeedBytes = 4 * 1024 * 1024
    private static let checkTimeout: TimeInterval = 20

    let feed: URL
    let trust: DownloadTrust
    private let downloadDirOverride: URL?

    /// Where release files are downloaded to. Only looked up when needed, so checking for
    /// a release never creates the data folder.
    var downloadDir: URL { downloadDirOverride ?? AppPaths.dataDir.appendingPathComponent("updates") }

    init(feed: URL = URL(string: AppInfo.latestReleaseApi)!, trust: DownloadTrust = .gitHubReleases,
         downloadDir: URL? = nil) {
        self.feed = feed
        self.trust = trust
        self.downloadDirOverride = downloadDir
    }

    /// The updater for this copy of the app, and how the copy is installed.
    struct Setup: Sendable {
        let service: UpdateService
        let kind: InstallKind
        let reason: InstallKindReason
        let isRehearsal: Bool
        /// A swap-helper step to fail on purpose; rehearsals only.
        let helperFailStep: String?
    }

    /// A trial run (one started on its own data folder, see `AppPaths.dataDirVariable`) can
    /// name a stand-in feed and install kind in TVCONTROL_UPDATE_FEED and
    /// TVCONTROL_INSTALL_KIND, to rehearse an update without publishing a release. Without
    /// a valid install kind a rehearsal is `.manual`, as TVControlForWin's is Portable; and
    /// a copy that isn't an app bundle stays `.none`, as there's nothing to replace.
    static func forThisCopy() -> Setup {
        let env = ProcessInfo.processInfo.environment
        let detected = detectInstallKind()
        if AppPaths.overrideDir != nil,
           let text = env[feedVariable], let feed = URL(string: text),
           let scheme = feed.scheme?.lowercased(), scheme == "http" || scheme == "https",
           let host = feed.host?.lowercased(), !host.isEmpty {
            let forced = InstallKind(rehearsalName: env[installKindVariable]) ?? .manual
            let kind = detected.kind == .none ? .none : forced
            let fail = env[helperFailVariable].flatMap { $0.isEmpty ? nil : $0 }
            return Setup(service: UpdateService(feed: feed, trust: .sameOrigin(host: host, port: DownloadTrust.effectivePort(feed))),
                         kind: kind, reason: detected.kind == .none ? detected.reason : .forced,
                         isRehearsal: true, helperFailStep: fail)
        }
        return Setup(service: UpdateService(), kind: detected.kind, reason: detected.reason,
                     isRehearsal: false, helperFailStep: nil)
    }

    // MARK: - Checking

    /// The latest published release, or nil when there isn't one that can be read as a
    /// version (including "nothing published yet", which GitHub answers with 404). Throws
    /// when the answer can't be had (offline, GitHub unreachable or refusing).
    func latest() async throws -> AppUpdate? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.checkTimeout
        config.timeoutIntervalForResource = Self.checkTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: feed)
        request.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError("no HTTP answer") }
        if http.statusCode == 404 { return nil } // nothing published yet
        guard (200..<300).contains(http.statusCode) else { throw UpdateError("the feed answered \(http.statusCode)") }
        guard data.count <= Self.maxFeedBytes else { throw UpdateError("the feed's answer is too big") }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let release = object as? [String: Any] else { return nil }
        return Self.parse(release: release, trust: trust)
    }

    /// Reads GitHub's release description. Nil for drafts, pre-releases and tags that
    /// aren't a version.
    static func parse(release: [String: Any], trust: DownloadTrust) -> AppUpdate? {
        if flag(release["draft"]) || flag(release["prerelease"]) { return nil }
        guard let version = AppInfo.parseVersion(release["tag_name"] as? String) else { return nil }

        // The page is opened in the browser, so only ever a GitHub web address.
        var page = URL(string: AppInfo.releasesPage)!
        if let text = release["html_url"] as? String, let url = URL(string: text), isGitHubPage(url) {
            page = url
        }

        func byHand(_ problem: String) -> AppUpdate {
            AppUpdate(version: version, pageURL: page, asset: nil, assetProblem: problem)
        }

        let expected = AppInfo.updateArchiveName(version: version)
        guard let assets = release["assets"] as? [Any] else { return byHand("the release lists no files") }
        for case let entry as [String: Any] in assets {
            guard let name = entry["name"] as? String, let nameVersion = archiveVersion(name),
                  AppInfo.compareVersions(nameVersion, version) == .orderedSame else { continue }

            // The first file of the expected name decides, as on Windows: one that isn't
            // fully described means updating by hand, never a fallback to another file.
            guard let digest = entry["digest"] as? String, digest.lowercased().hasPrefix("sha256:") else {
                return byHand("\(name) has no SHA-256 digest")
            }
            let hex = digest.dropFirst("sha256:".count).trimmingCharacters(in: .whitespaces).lowercased()
            guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
                return byHand("\(name) has a malformed SHA-256 digest")
            }
            guard let size = integer(entry["size"]), size > 0, size <= maxArchiveBytes else {
                return byHand("\(name) has no usable size")
            }
            guard let text = entry["browser_download_url"] as? String, let url = URL(string: text),
                  trust.allows(url, name: name) else {
                return byHand("\(name) isn't where a release's files belong")
            }
            return AppUpdate(version: version, pageURL: page,
                             asset: ReleaseAsset(name: name, version: nameVersion, url: url, size: size, sha256: hex),
                             assetProblem: nil)
        }
        return byHand("the release has no \(expected)")
    }

    /// The version in a release file name like "TVControlForMac-3.0.1.zip", exactly as
    /// written; nil for any other name. Matched without regard to case, like Windows.
    static func archiveVersion(_ name: String) -> String? {
        let prefix = AppInfo.name + "-", suffix = ".zip"
        guard name.count > prefix.count + suffix.count,
              name.lowercased().hasPrefix(prefix.lowercased()),
              name.lowercased().hasSuffix(suffix) else { return nil }
        let middle = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        let parts = middle.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        return middle
    }

    static func isGitHubPage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
    }

    // JSON true only: 1 or "true" don't count, as with System.Text.Json's ValueKind.True.
    private static func flag(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double == double.rounded(), double >= 0, double <= Double(Int64.max / 2) else { return nil }
        return number.int64Value
    }

    // MARK: - Downloading

    /// Downloads the release's zip and checks it against the size and hash GitHub lists for
    /// it. Returns the verified file. `progress` gets 0...1 on an arbitrary queue.
    func download(_ update: AppUpdate, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let asset = update.asset else { throw UpdateError("this release has nothing to install") }
        guard trust.allows(asset.url, name: asset.name) else {
            throw UpdateError("the file isn't where a release's files belong")
        }

        let files = FileManager.default
        try files.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        let target = downloadDir.appendingPathComponent(asset.name)
        if Self.matches(target, asset) {
            progress(1)
            return target // already downloaded, e.g. before a restart
        }

        // Only ever one release file on disk: whatever was here is for an older update, or broken.
        for old in (try? files.contentsOfDirectory(at: downloadDir, includingPropertiesForKeys: nil)) ?? [] {
            try? files.removeItem(at: old) // in use or protected: leave it
        }

        let part = downloadDir.appendingPathComponent(asset.name + ".part")
        defer { try? files.removeItem(at: part) }
        try await Self.fetch(asset.url, to: part, limit: asset.size, progress: progress)

        guard Self.matches(part, asset) else { throw UpdateError("the download doesn't match the release") }
        try? files.removeItem(at: target)
        try files.moveItem(at: part, to: target)
        guard Self.matches(target, asset) else { throw UpdateError("the download didn't land on disk intact") }
        return target
    }

    /// Clears out downloads that have served their purpose: release files for this version
    /// or older (the update went in, or is no longer newer), and anything half-downloaded.
    func deleteUsedDownloads() {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(at: downloadDir, includingPropertiesForKeys: nil) else { return }
        for file in entries {
            if let version = Self.archiveVersion(file.lastPathComponent),
               AppInfo.compareVersions(version, AppInfo.version) == .orderedDescending { continue } // still to go in
            try? files.removeItem(at: file) // in use or protected: next time
        }
    }

    /// True when `file` exists with exactly the asset's size and SHA-256.
    static func matches(_ file: URL, _ asset: ReleaseAsset) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == asset.size else { return false }
        return sha256(of: file) == asset.sha256
    }

    /// Lowercase hex SHA-256 of a file, or nil if it can't be read.
    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // nil (or empty) is the end of the file; a read error throws.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Streams a response body to a file, stopping as soon as it outgrows what the release
    // says the file is: a larger answer is wrong whatever its hash would turn out to be.
    private static func fetch(_ url: URL, to file: URL, limit: Int64,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else {
            throw UpdateError("can't write to \(file.deletingLastPathComponent().path)")
        }
        defer { try? handle.close() }

        let receiver = DownloadReceiver(handle: handle, limit: limit, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 30 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1 // the receiver's state is touched from one queue only
        let session = URLSession(configuration: config, delegate: receiver, delegateQueue: queue)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                receiver.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Install kind

    /// Whether this copy can replace itself where it is.
    static func detectInstallKind(bundleURL: URL = Bundle.main.bundleURL,
                                  bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> (kind: InstallKind, reason: InstallKindReason) {
        let bundle = bundleURL.standardizedFileURL
        let parent = bundle.deletingLastPathComponent()
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? true
        let location = InstallLocation(
            bundlePath: bundle.path,
            isAppBundle: bundle.pathExtension.lowercased() == "app" && bundleIdentifier == AppInfo.bundleIdentifier,
            isReadOnlyVolume: readOnly,
            parentWritable: access(parent.path, W_OK) == 0,
            bundleWritable: access(bundle.path, W_OK) == 0)
        return classify(location)
    }

    /// The decision behind `detectInstallKind`, on given facts.
    static func classify(_ location: InstallLocation) -> (kind: InstallKind, reason: InstallKindReason) {
        guard location.isAppBundle else { return (.none, .notABundle) }
        // A translocated app runs from a read-only mount of a random folder; replacing that
        // would change nothing the user sees, so it's checked before anything else.
        if location.bundlePath.contains("/AppTranslocation/") { return (.manual, .translocated) }
        if location.isReadOnlyVolume { return (.manual, .readOnlyVolume) }
        if !location.parentWritable || !location.bundleWritable { return (.manual, .notWritable) }
        return (.selfUpdating, .replaceable)
    }

    // MARK: - Staging and checking the new app

    /// Unpacks a downloaded (and hash-checked) release zip into a staging folder on the
    /// same volume as `app`, and checks what came out. Nothing outside the staging folder is
    /// touched; on any failure the staging folder is removed again.
    static func stage(archive: URL, version: String, nextTo app: URL) throws -> StagedUpdate {
        let files = FileManager.default
        // The swap is a pair of renames, which only stay atomic within one volume.
        let root = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: app, create: true)
        do {
            guard volume(of: root) != nil, volume(of: root) == volume(of: app.deletingLastPathComponent()) else {
                throw UpdateError("couldn't find a staging folder on the app's volume")
            }

            try checkArchive(Data(contentsOf: archive, options: .mappedIfSafe))

            let unpacked = root.appendingPathComponent("new")
            try files.createDirectory(at: unpacked, withIntermediateDirectories: false)
            let ditto = try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
            guard ditto.status == 0 else { throw UpdateError("couldn't unpack the zip (\(ditto.output))") }

            let contents = try files.contentsOfDirectory(atPath: unpacked.path)
            guard contents == [AppInfo.name + ".app"] else {
                throw UpdateError("the zip holds \(contents.sorted()), not just \(AppInfo.name).app")
            }
            let bundle = unpacked.appendingPathComponent(AppInfo.name + ".app")
            try checkTree(bundle)
            try clearQuarantine(bundle)
            try verifyBundle(bundle, version: version)
            return StagedUpdate(root: root, bundle: bundle, version: version)
        } catch {
            try? files.removeItem(at: root)
            throw error
        }
    }

    /// One entry of a zip's central directory.
    struct ArchiveEntry: Equatable, Sendable {
        let name: String
        let isSymlink: Bool
        /// Unix permission and type bits, when the zip was made on a Unix system.
        let mode: UInt32?
    }

    /// Reads a zip's table of contents without unpacking anything.
    static func archiveEntries(_ data: Data) throws -> [ArchiveEntry] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        // The end-of-central-directory record is at the end, before a comment of up to 64 KB.
        guard bytes.count >= 22 else { throw UpdateError("the zip is too short") }
        var eocd: Int?
        var at = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        while at >= lowest {
            if u32(at) == 0x0605_4b50 { eocd = at; break }
            at -= 1
        }
        guard let end = eocd else { throw UpdateError("the zip has no table of contents") }
        let count = u16(end + 10), size = u32(end + 12), offset = u32(end + 16)
        guard u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == count else {
            throw UpdateError("multi-part zips aren't accepted")
        }
        guard count != 0xFFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else {
            throw UpdateError("zip64 archives aren't accepted")
        }
        guard count > 0, count <= 20000, offset + size <= end else { throw UpdateError("the zip's table of contents is damaged") }

        var entries: [ArchiveEntry] = []
        var position = offset
        for _ in 0..<count {
            guard position + 46 <= end, u32(position) == 0x0201_4b50 else {
                throw UpdateError("the zip's table of contents is damaged")
            }
            let madeBy = u16(position + 4) >> 8
            let nameLength = u16(position + 28), extraLength = u16(position + 30), commentLength = u16(position + 32)
            let external = UInt32(truncatingIfNeeded: u32(position + 38))
            guard position + 46 + nameLength <= end else { throw UpdateError("the zip's table of contents is damaged") }
            guard let name = String(bytes: bytes[(position + 46)..<(position + 46 + nameLength)], encoding: .utf8) else {
                throw UpdateError("a name in the zip isn't readable")
            }
            let mode: UInt32? = madeBy == 3 ? external >> 16 : nil // 3: made on Unix
            entries.append(ArchiveEntry(name: name, isSymlink: mode.map { $0 & 0o170000 == 0o120000 } ?? false, mode: mode))
            position += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Refuses a zip that could write outside the folder it's unpacked into: absolute
    /// names, "..", anything but the app (and ditto's __MACOSX metadata), and paths that run
    /// through a symbolic link stored earlier in the same zip.
    static func checkArchive(_ data: Data) throws {
        let entries = try archiveEntries(data)
        let app = AppInfo.name + ".app"
        var links: [String] = []
        var hasInfoPlist = false
        for entry in entries {
            let name = entry.name
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else {
                throw UpdateError("the zip has an unsafe name: \(name)")
            }
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() {
                let isTrailingSlash = index == parts.count - 1 && part.isEmpty && index > 0
                guard isTrailingSlash || (!part.isEmpty && part != "." && part != "..") else {
                    throw UpdateError("the zip has an unsafe name: \(name)")
                }
            }
            guard parts[0] == app || parts[0] == "__MACOSX" else {
                throw UpdateError("the zip has something besides the app: \(name)")
            }
            if let mode = entry.mode, mode & 0o6000 != 0 { throw UpdateError("the zip has a setuid file: \(name)") }
            if entry.isSymlink {
                guard parts[0] == app else { throw UpdateError("the zip has a link outside the app: \(name)") }
                links.append(name)
            }
            if name == "\(app)/Contents/Info.plist" { hasInfoPlist = true }
        }
        for entry in entries {
            for link in links where entry.name != link && entry.name.hasPrefix(link + "/") {
                throw UpdateError("the zip writes through a link: \(entry.name)")
            }
        }
        guard hasInfoPlist else { throw UpdateError("the zip has no \(app)/Contents/Info.plist") }
    }

    /// Checks the unpacked bundle on disk: only folders, plain files, and links that stay
    /// inside the bundle; no setuid or setgid bits.
    static func checkTree(_ bundle: URL) throws {
        let files = FileManager.default
        let base = bundle.standardizedFileURL.path
        guard let walker = files.enumerator(atPath: base) else { throw UpdateError("can't read the unpacked app") }
        while let relative = walker.nextObject() as? String {
            let path = base + "/" + relative
            let attributes = try files.attributesOfItem(atPath: path)
            let type = attributes[.type] as? FileAttributeType
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard permissions & 0o6000 == 0 else { throw UpdateError("setuid or setgid file: \(relative)") }
            switch type {
            case .typeDirectory?, .typeRegular?:
                continue
            case .typeSymbolicLink?:
                let target = try files.destinationOfSymbolicLink(atPath: path)
                guard !target.hasPrefix("/") else { throw UpdateError("link to an absolute path: \(relative)") }
                let resolved = ((path as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent(target)
                let standardized = (resolved as NSString).standardizingPath
                guard standardized.hasPrefix(base + "/") else { throw UpdateError("link out of the app: \(relative)") }
            default:
                throw UpdateError("unexpected kind of file: \(relative)")
            }
        }
    }

    /// Removes the quarantine flag from everything in the bundle, then makes sure it's gone:
    /// a quarantined self-signed app would be stopped by Gatekeeper when the swap starts it.
    static func clearQuarantine(_ bundle: URL) throws {
        let name = "com.apple.quarantine"
        var paths = [bundle.path]
        if let walker = FileManager.default.enumerator(atPath: bundle.path) {
            while let relative = walker.nextObject() as? String { paths.append(bundle.path + "/" + relative) }
        }
        for path in paths {
            if getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 {
                _ = removexattr(path, name, XATTR_NOFOLLOW)
                guard getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) < 0 else {
                    throw UpdateError("couldn't clear the quarantine flag on \(path)")
                }
            }
        }
    }

    /// The unpacked app must be this app, at exactly `version`, with a valid signature, and
    /// signed by the same signer as the running copy when that has a real certificate.
    /// `signer` defaults to that rule; nil checks the signature's validity only.
    static func verifyBundle(_ bundle: URL, version: String,
                             signer: SecRequirement? = CodeSigning.updateRequirement()) throws {
        guard bundle.lastPathComponent == AppInfo.name + ".app" else {
            throw UpdateError("the app is called \(bundle.lastPathComponent)")
        }
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateError("the app has no readable Info.plist")
        }
        let identifier = plist["CFBundleIdentifier"] as? String
        guard identifier == AppInfo.bundleIdentifier else {
            throw UpdateError("the app's identifier is \(identifier ?? "missing"), not \(AppInfo.bundleIdentifier)")
        }
        let found = plist["CFBundleShortVersionString"] as? String
        guard found == version else { throw UpdateError("the app says version \(found ?? "nothing"), not \(version)") }
        guard let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/") else {
            throw UpdateError("the app names no executable")
        }
        let binary = bundle.appendingPathComponent("Contents/MacOS/\(executable)").path
        guard (try? FileManager.default.attributesOfItem(atPath: binary))?[.type] as? FileAttributeType == .typeRegular,
              access(binary, X_OK) == 0 else {
            throw UpdateError("the app's executable is missing")
        }

        try CodeSigning.check(bundle, requirement: signer)
    }

    // MARK: - The swap

    /// Starts the helper that swaps the staged app in once this process has exited, and
    /// returns its process id. The caller quits the app right after.
    ///
    /// The helper is one `/bin/sh` script in its own session, so it outlives the app. It
    /// waits (up to a minute) for this process to exit, moves the running bundle aside,
    /// moves the new one into its place, checks it says the new version, and starts it with
    /// `--updated`. If any step fails it puts the old bundle back and starts that instead,
    /// so the Mac is never left without the app, and the TVs not without their rules.
    ///
    /// - Parameter quiet: an update nobody is watching: the app comes back without its
    ///   window (`--background`) and without taking focus.
    static func launchSwap(_ staged: StagedUpdate, replacing app: URL, quiet: Bool,
                           failStep: String? = nil) throws -> pid_t {
        let aside = staged.root.appendingPathComponent("previous.app")
        let log = AppPaths.dataDir.appendingPathComponent("log.txt")

        var openArgs: [String] = quiet ? ["-g"] : []
        // A rehearsal's data folder and stand-ins must follow the app across the restart, or
        // the new copy would start on the real data folder.
        if AppPaths.isTrialRun {
            let env = ProcessInfo.processInfo.environment
            for name in [AppPaths.dataDirVariable, feedVariable, installKindVariable] {
                if let value = env[name] { openArgs += ["--env", "\(name)=\(value)"] }
            }
        }
        let appArgs = quiet ? [AppInfo.updatedArg, AppInfo.backgroundArg] : [AppInfo.updatedArg]

        let arguments = ["/bin/sh", "-c", swapScript, "tvcontrol-update",
                         String(getpid()), app.path, staged.bundle.path, aside.path, staged.root.path,
                         staged.version, log.path, failStep ?? "", appArgs.joined(separator: " ")] + openArgs
        let pid = try spawnDetached(arguments)
        guard kill(pid, 0) == 0 else { throw UpdateError("the update helper didn't start") }
        return pid
    }

    // Positional: pid app new aside stage version log fail appargs [open options...].
    // Each step is checked on disk, not taken on its word. The old bundle is only ever
    // deleted together with the staging folder, after the new one is in place and started.
    static let swapScript = #"""
    pid=$1; app=$2; new=$3; aside=$4; stage=$5; version=$6; log=$7; fail=$8; appargs=$9
    shift 9
    PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
    say() { printf '%s  update: %s\n' "$(date '+%Y-%m-%d %H:%M:%S.000')" "$1" >>"$log" 2>/dev/null; }
    step() { if [ "$fail" = "$1" ]; then say "rehearsal: failing \"$1\" on purpose"; return 1; fi; return 0; }
    plistver() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
    start() { open "$@" "$app" --args $appargs; }
    giveup() { rm -rf "$stage"; exit 1; }
    restore() {
        say "$1; putting the previous version back"
        shift
        if [ -e "$app" ]; then mv "$app" "$stage/failed.app" 2>/dev/null || rm -rf "$app"; fi
        if [ -e "$app" ] || ! mv "$aside" "$app" || [ ! -d "$app" ]; then
            say "couldn't put the previous version back; it is at $aside"
            exit 1
        fi
        if start "$@"; then say "the previous version is back"; else say "couldn't start the previous version"; fi
        giveup
    }

    n=0
    while kill -0 "$pid" 2>/dev/null; do
        n=$((n + 1))
        if [ "$n" -gt 300 ]; then say "the app didn't quit; update not installed"; giveup; fi
        sleep 0.2
    done

    if ! step move-aside || ! mv "$app" "$aside" || [ -e "$app" ] || [ ! -d "$aside" ]; then
        say "couldn't move the running version aside"
        if [ ! -e "$app" ] && [ -d "$aside" ]; then mv "$aside" "$app"; fi
        start "$@"
        giveup
    fi
    if ! step move-new || ! mv "$new" "$app" || [ ! -d "$app" ]; then restore "couldn't move $version into place" "$@"; fi
    xattr -dr com.apple.quarantine "$app" 2>/dev/null
    if ! step verify || [ "$(plistver "$app")" != "$version" ]; then restore "the app in place isn't $version" "$@"; fi
    if ! step launch || ! start "$@"; then restore "couldn't start $version" "$@"; fi
    say "installed $version"
    rm -rf "$stage"
    exit 0
    """#

    // posix_spawn rather than Process: a new session (setsid) cuts the helper loose from
    // the app entirely, and only the standard descriptors (pointed at /dev/null) are passed
    // on, so it doesn't hold any of the app's sockets or files open.
    private static func spawnDetached(_ arguments: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, "/") // not the app's folder: it's about to move

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, arguments[0], &actions, &attributes, &argv, environ)
        guard status == 0 else { throw UpdateError("couldn't start the update helper (\(String(cString: strerror(status))))") }
        return pid
    }

    // MARK: - Helpers

    private static func volume(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    /// Runs a tool to completion and returns its exit status and combined output.
    static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}

/// Receives a download's bytes into a file, refusing more than the expected size.
private final class DownloadReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Touched only from the session's serial delegate queue, after `continuation` is set.
    private let handle: FileHandle
    private let limit: Int64
    private let progress: @Sendable (Double) -> Void
    private var written: Int64 = 0
    private var failure: Error?
    var continuation: CheckedContinuation<Void, Error>?

    init(handle: FileHandle, limit: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.handle = handle
        self.limit = limit
        self.progress = progress
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = UpdateError("the download answered \(http.statusCode)")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        written += Int64(data.count)
        guard written <= limit else {
            failure = UpdateError("the download is bigger than the release says")
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        progress(Double(written) / Double(limit))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome = failure ?? error
        let continuation = self.continuation
        self.continuation = nil
        if let outcome { continuation?.resume(throwing: outcome) } else { continuation?.resume() }
    }
}

/// Code-signature checks for an update, through the Security framework.
enum CodeSigning {
    /// How a piece of code is signed.
    struct Identity {
        let isSigned: Bool
        let isAdHoc: Bool
        /// The leaf certificate's name, for a real signature.
        let authority: String?
        let designatedRequirement: SecRequirement?
        var requirementText: String? { designatedRequirement.flatMap(CodeSigning.text) }
        /// Signed with a certificate (self-signed counts), as opposed to ad hoc.
        var hasCertificate: Bool { isSigned && !isAdHoc && authority != nil }
    }

    // Strict, every architecture, nested code included, and no links out of the bundle:
    // the same ground `codesign --verify --deep --strict` covers.
    static let validityFlags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures)
        | UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckNestedCode) | UInt32(kSecCSRestrictSymlinks))

    /// The running app's signature.
    static func running() -> Identity? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return identity(of: staticCode)
    }

    /// The signature of the bundle or binary at `url`.
    static func identity(at url: URL) -> Identity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return identity(of: staticCode)
    }

    private static func identity(of code: SecStaticCode) -> Identity {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return Identity(isSigned: false, isAdHoc: false, authority: nil, designatedRequirement: nil)
        }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isSigned = dict[kSecCodeInfoIdentifier as String] != nil
        let isAdHoc = flags & UInt32(SecCodeSignatureFlags.adhoc.rawValue) != 0
        var authority: String?
        if let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first {
            authority = SecCertificateCopySubjectSummary(leaf) as String?
        }
        var requirement: SecRequirement?
        if isSigned, SecCodeCopyDesignatedRequirement(code, [], &requirement) != errSecSuccess { requirement = nil }
        return Identity(isSigned: isSigned, isAdHoc: isAdHoc, authority: authority, designatedRequirement: requirement)
    }

    /// What an update's signer must satisfy: the running app's designated requirement when
    /// it's signed with a certificate, so an update has to come from the same signer. An
    /// ad-hoc signature's requirement is its own code hash, which no other build can ever
    /// meet, so there the signer can't be checked and only the signature's validity is.
    static func updateRequirement() -> SecRequirement? {
        guard let me = running() else {
            Log.write("update: this copy isn't signed; the update's signer can't be compared")
            return nil
        }
        guard me.hasCertificate, let requirement = me.designatedRequirement else {
            Log.write("update: this copy is signed ad hoc; checking the update's signature but not its signer")
            return nil
        }
        return requirement
    }

    /// Throws unless the code at `url` has a valid signature (and satisfies `requirement`).
    static func check(_ url: URL, requirement: SecRequirement?) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError("can't read the app's signature")
        }
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, validityFlags, requirement, &error)
        guard status == errSecSuccess else {
            _ = error?.takeRetainedValue()
            let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
            if status == errSecCSReqFailed {
                throw UpdateError("the app isn't signed by the same signer as this copy (\(detail))")
            }
            throw UpdateError("the app's signature isn't valid (\(detail))")
        }
    }

    static func text(_ requirement: SecRequirement) -> String? {
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }
}
