// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Facts about the app itself: its name, version, and where its releases are published.
enum AppInfo {
    static let name = "TVControlForMac"

    static let bundleIdentifier = "com.itsallexb.TVControlForMac"

    /// The bundle id the app had while it was called LGforMac (up to v1.0). A copy of
    /// that still running is asked to quit at launch, so the two don't fight over the TVs.
    static let legacyBundleIdentifier = "com.itsallexb.LGforMac"

    /// The running version as "3.0.0" (Info.plist's CFBundleShortVersionString). The
    /// fallback only matters when the binary runs outside its bundle (the diagnostics CLI).
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0.0"

    /// The GitHub repository releases are published to.
    static let repository = "itsAllexB/TVControlForMac"

    /// GitHub's description of the newest published release (not drafts or pre-releases).
    static let latestReleaseApi = "https://api.github.com/repos/\(repository)/releases/latest"

    /// The page a person downloads the newest release from.
    static let releasesPage = "https://github.com/\(repository)/releases/latest"

    /// Where a release's files are downloaded from. GitHub treats owner and repository
    /// names case-insensitively, so this is compared that way.
    static let releaseDownloadPrefix = "https://github.com/\(repository)/releases/download/"

    /// The release file the updater installs: the zipped app that `build.sh release
    /// --package` writes. Nothing else in a release is ever installed.
    static func updateArchiveName(version: String) -> String { "\(name)-\(version).zip" }

    /// Launch argument: the app is coming back after installing an update, not being
    /// started by the user or by macOS.
    static let updatedArg = "--updated"

    /// Launch argument: start without opening the window, as a menu bar app only. The
    /// updater adds it when an update went in unattended, so the app returns to the
    /// background state it was in (TVControlForWin's `--tray`).
    static let backgroundArg = "--background"

    /// True when this process is the app coming back after an update (or after an update
    /// that failed and put the old version back). Not a start by the user or at login.
    static var launchedAfterUpdate: Bool { CommandLine.arguments.contains(updatedArg) }

    /// True when this process was asked to start without its window.
    static var launchedInBackground: Bool { CommandLine.arguments.contains(backgroundArg) }

    /// "v3.1.0", "3.1" or "3.1.0-beta" as a three-part version ("3.1.0"); nil if it isn't
    /// one. Like System.Version on Windows: two to four numeric parts, the fourth dropped,
    /// anything after "-" or "+" ignored.
    static func parseVersion(_ tag: String?) -> String? {
        guard var text = tag?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        while text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let end = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { text = String(text[..<end]) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        return numbers.prefix(3).map(String.init).joined(separator: ".")
    }

    /// Compares two dotted versions numerically, missing parts counting as 0, so "3.1"
    /// and "3.1.0" are equal. A leading "v" is ignored.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let left = versionParts(a), right = versionParts(b)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func versionParts(_ version: String) -> [Int] {
        let trimmed = version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
        return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
