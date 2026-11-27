// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Where the app keeps its files (TVs, settings, log).
enum AppPaths {
    /// Environment variable that points the app at a different data folder. An instance
    /// started with it set also runs alongside the normal one instead of handing over to
    /// it, for trying a build against throwaway data without touching the real TVs and
    /// settings. Same name as TVControlForWin uses.
    static let dataDirVariable = "TVCONTROL_DATA_DIR"

    // The app was called LGforMac up to v1.0; its data folder is carried over on first run.
    private static let legacyFolder = "LGforMac"
    private static let folder = "TVControlForMac"

    /// The data folder. Created (and migrated from the old name) on first use.
    static let dataDir: URL = resolve()

    /// The override folder when `dataDirVariable` is set, otherwise nil.
    static var overrideDir: URL? {
        guard let value = ProcessInfo.processInfo.environment[dataDirVariable],
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// True for a side-by-side trial run on its own data folder. Such a run leaves the
    /// login item alone, doesn't check for updates by itself, and isn't single-instance.
    static var isTrialRun: Bool { overrideDir != nil }

    private static func resolve() -> URL {
        let files = FileManager.default
        if let custom = overrideDir {
            try? files.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }

        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent(folder)
        if !files.fileExists(atPath: dir.path) {
            try? files.createDirectory(at: dir, withIntermediateDirectories: true)
            copyLegacyData(from: support.appendingPathComponent(legacyFolder), to: dir)
        }
        return dir
    }

    // Copied rather than moved: the old folder may be open in a still-running old version,
    // and leaving it lets that version keep working if someone goes back to it.
    private static func copyLegacyData(from: URL, to: URL) {
        let files = FileManager.default
        guard files.fileExists(atPath: from.path) else { return }
        for name in ["devices.json", "settings.json"] {
            let source = from.appendingPathComponent(name)
            if files.fileExists(atPath: source.path) {
                // Best effort: worst case the app starts with no TVs and they're re-added.
                try? files.copyItem(at: source, to: to.appendingPathComponent(name))
            }
        }
    }
}
