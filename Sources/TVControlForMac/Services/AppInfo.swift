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

    /// Launch argument: the app is coming back after installing an update, not being
    /// started by the user or by macOS.
    static let updatedArg = "--updated"

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
