// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Loads and saves the TV list (incl. pairing credentials) plus app settings as JSON in
/// the data folder (`AppPaths.dataDir`). Credential reuse avoids re-pairing every launch.
final class DeviceStore {
    static var directory: URL { AppPaths.dataDir }

    private let devicesURL = AppPaths.dataDir.appendingPathComponent("devices.json")
    private let settingsURL = AppPaths.dataDir.appendingPathComponent("settings.json")

    // Saves can be asked for from any thread (a controller that just learned a MAC, the
    // UI changing a setting); one at a time, so a slower write can't land over a newer one.
    private let gate = NSLock()

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    func loadDevices() -> [TvDevice] {
        guard let data = try? Data(contentsOf: devicesURL) else { return [] }
        if let devices = try? JSONDecoder().decode([TvDevice].self, from: data) { return devices }
        Self.keepUnreadable(devicesURL)
        return []
    }

    func saveDevices(_ devices: [TvDevice]) {
        gate.lock(); defer { gate.unlock() }
        if let data = try? Self.encoder().encode(devices) {
            try? data.write(to: devicesURL, options: .atomic)
        }
    }

    func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return AppSettings() }
        if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) { return settings }
        Self.keepUnreadable(settingsURL)
        return AppSettings()
    }

    /// A file that's there but can't be read (cut short, edited by hand) loads as empty, and
    /// the next save would replace it for good. So a copy is kept next to it first, as
    /// "<name>.unreadable": one per file, the latest replacing an older one.
    static func keepUnreadable(_ url: URL) {
        let copy = url.appendingPathExtension("unreadable")
        let files = FileManager.default
        if files.contentsEqual(atPath: url.path, andPath: copy.path) { return } // kept already
        try? files.removeItem(at: copy)
        do {
            try files.copyItem(at: url, to: copy)
            Log.write("\(url.lastPathComponent) can't be read; starting without it, a copy is in \(copy.lastPathComponent)")
        } catch {
            Log.write("\(url.lastPathComponent) can't be read, and keeping a copy failed: \(error.localizedDescription)")
        }
    }

    func saveSettings(_ settings: AppSettings) {
        gate.lock(); defer { gate.unlock() }
        if let data = try? Self.encoder().encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    /// Serializes the full configuration (TVs + settings) to a single JSON backup string.
    func serializeBackup(devices: [TvDevice], settings: AppSettings) -> String {
        let backup = BackupData(devices: devices, settings: settings)
        guard let data = try? Self.encoder().encode(backup) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses a backup string; throws if the file isn't a valid TVControlForMac /
    /// TVControlForWin backup.
    func deserializeBackup(_ json: String) throws -> BackupData {
        let data = try JSONDecoder().decode(BackupData.self, from: Data(json.utf8))
        // Importing replaces everything: a JSON file picked by mistake mustn't read as an
        // empty backup. Both apps always write both sections, so a file missing either
        // isn't one; a settings-only file would otherwise remove every TV and its pairing.
        guard data.devices != nil && data.settings != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a settings backup."))
        }
        return data
    }
}

/// Tiny append-only logger to `log.txt` in the data folder.
enum Log {
    private static let gate = NSLock()
    private static let url = AppPaths.dataDir.appendingPathComponent("log.txt")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        gate.lock()
        defer { gate.unlock() }
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        // Keep the log small: reset if it grows past ~256 KB.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 256 * 1024 {
            try? Data().write(to: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
