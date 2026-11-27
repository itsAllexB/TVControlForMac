// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Which control protocol a TV speaks. Stored as a number in devices.json; 0 is webOS so
/// files written before other kinds existed still load as LG TVs.
enum TvKind: Int, Codable {
    /// LG webOS: SSAP over a WebSocket. Brightness, screen off and power.
    case webOs = 0
    /// Android TV / Google TV (TCL, Sony, Philips, Hisense, Xiaomi, Chromecast…): the
    /// Android TV Remote protocol. Power only; brightness goes over ADB where a brand allows it.
    case androidTv = 1

    /// Short protocol name shown next to the address, e.g. "LG webOS".
    var label: String {
        switch self {
        case .webOs: "LG webOS"
        case .androidTv: "Google TV"
        }
    }

    /// The name a TV of this kind gets when the user doesn't give one.
    var defaultName: String {
        switch self {
        case .webOs: "LG TV"
        case .androidTv: "Google TV"
        }
    }
}

/// Persisted description of a single TV plus its last-known state.
/// JSON keys match TVControlForWin's `devices.json` exactly, so a backup made on Windows
/// imports here unchanged and the other way round (pairing credentials carry over).
final class TvDevice: Codable, Identifiable {
    /// Stable identity for this TV, so rules (schedules, power, hotkeys) can name the TVs
    /// they apply to and survive a rename or a new IP address. Never empty: files written
    /// before it existed get one as they load (see `idWasAssigned`).
    var id: String
    var name: String = "LG TV"
    var host: String = ""
    /// The protocol this TV is controlled with.
    var kind: TvKind = .webOs
    /// webOS: pairing key returned by the TV on first accept; reused so the prompt never reappears.
    var clientKey: String = ""
    /// Android TV: the certificate (base64 PKCS#12, private key included) this app paired
    /// with. The TV trusts whoever presents it, so it plays the role `clientKey` does for
    /// webOS. Only saved once pairing succeeds; empty means "not paired".
    var clientCertificate: String = ""
    /// Android TV: the RSA key (base64 PKCS#8) the TV has approved for ADB, which is how
    /// its picture brightness is reached. Saved once brightness setup succeeds.
    var adbKey: String = ""
    /// Last brightness (OLED Light / backlight) value 0-100 we set, for UI restore.
    var lastBacklight: Int = 80
    /// Stable id (display UUID) of the screen this TV drives, for cursor-targeted hotkeys and the OSD.
    var pairedScreenId: String = ""
    /// Friendly name of the linked display, so the UI can name it while it's unplugged.
    var pairedScreenName: String = ""
    /// When true, automation (schedules, power rules, hotkeys) skips this TV while its
    /// linked display isn't connected to this Mac.
    var automationOnlyWhenConnected: Bool = false
    /// Whether the linked display was present the last time the Mac was awake with its
    /// displays on. A TV that's off drops its HDMI link entirely, so wake-time rules
    /// can't trust a live check; they use this snapshot instead.
    var lastDisplayConnected: Bool = true
    /// webOS: true once a secure wss://:3001 connection succeeded (2022+ models); tried first on reconnect.
    var secure: Bool = false
    /// MAC address(es) learned while reachable, needed for Wake-on-LAN once the TV is off.
    var macAddress: String = ""
    /// This TV's own power rules (Power page). Nil, the default, means it follows the
    /// shared rules in `AppSettings.power`.
    var power: PowerSettings?

    /// True when `id` was made up while decoding (a file from before ids existed), so the
    /// owner knows to save it back straight away. Not persisted.
    private(set) var idWasAssigned = false

    static func newId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    init(name: String = "LG TV", host: String = "", kind: TvKind = .webOs) {
        self.id = Self.newId()
        self.name = name
        self.host = host
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", host = "Host", kind = "Kind"
        case clientKey = "ClientKey", clientCertificate = "ClientCertificate", adbKey = "AdbKey"
        case lastBacklight = "LastBacklight", pairedScreenId = "PairedScreenId"
        case pairedScreenName = "PairedScreenName"
        case automationOnlyWhenConnected = "AutomationOnlyWhenConnected"
        case lastDisplayConnected = "LastDisplayConnected"
        case secure = "Secure", macAddress = "MacAddress", power = "Power"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedId = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        id = storedId.isEmpty ? Self.newId() : storedId
        idWasAssigned = storedId.isEmpty
        kind = TvKind(rawValue: try c.decodeIfPresent(Int.self, forKey: .kind) ?? 0) ?? .webOs
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? kind.defaultName
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        clientKey = try c.decodeIfPresent(String.self, forKey: .clientKey) ?? ""
        clientCertificate = try c.decodeIfPresent(String.self, forKey: .clientCertificate) ?? ""
        adbKey = try c.decodeIfPresent(String.self, forKey: .adbKey) ?? ""
        lastBacklight = try c.decodeIfPresent(Int.self, forKey: .lastBacklight) ?? 80
        pairedScreenId = try c.decodeIfPresent(String.self, forKey: .pairedScreenId) ?? ""
        pairedScreenName = try c.decodeIfPresent(String.self, forKey: .pairedScreenName) ?? ""
        automationOnlyWhenConnected = try c.decodeIfPresent(Bool.self, forKey: .automationOnlyWhenConnected) ?? false
        lastDisplayConnected = try c.decodeIfPresent(Bool.self, forKey: .lastDisplayConnected) ?? true
        secure = try c.decodeIfPresent(Bool.self, forKey: .secure) ?? false
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress) ?? ""
        power = try c.decodeIfPresent(PowerSettings.self, forKey: .power)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(clientKey, forKey: .clientKey)
        try c.encode(clientCertificate, forKey: .clientCertificate)
        try c.encode(adbKey, forKey: .adbKey)
        try c.encode(lastBacklight, forKey: .lastBacklight)
        try c.encode(pairedScreenId, forKey: .pairedScreenId)
        try c.encode(pairedScreenName, forKey: .pairedScreenName)
        try c.encode(automationOnlyWhenConnected, forKey: .automationOnlyWhenConnected)
        try c.encode(lastDisplayConnected, forKey: .lastDisplayConnected)
        try c.encode(secure, forKey: .secure)
        try c.encode(macAddress, forKey: .macAddress)
        try c.encodeIfPresent(power, forKey: .power)
    }
}

/// A time-of-day rule: at Hour:Minute set the brightness of the TVs it targets. Fires daily.
struct BrightnessSchedule: Codable, Identifiable, Equatable {
    var hour: Int = 8
    var minute: Int = 0
    var brightness: Int = 50
    var enabled: Bool = true
    /// Ids (`TvDevice.id`) of the TVs this schedule changes. Empty means all TVs, which is
    /// also what files written before this existed load as.
    var tvIds: [String] = []

    var id = UUID()

    enum CodingKeys: String, CodingKey {
        case hour = "Hour", minute = "Minute", brightness = "Brightness", enabled = "Enabled"
        case tvIds = "TvIds"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 8
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        brightness = try c.decodeIfPresent(Int.self, forKey: .brightness) ?? 50
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        tvIds = try c.decodeIfPresent([String].self, forKey: .tvIds) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hour, forKey: .hour)
        try c.encode(minute, forKey: .minute)
        try c.encode(brightness, forKey: .brightness)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(tvIds, forKey: .tvIds)
    }

    var minutesOfDay: Int { hour * 60 + minute }
}

/// Preferences for the on-screen display shown when brightness changes via hotkeys.
struct OsdSettings: Codable {
    var enabled: Bool = true
    /// Overlay style: 0 = macOS system pop-up (below the menu bar, like the native
    /// volume/brightness HUD, the default), 1 = Windows-style pill.
    var style: Int = 0
    /// Anchor for the Windows style: 0 bottom-centre, 1 bottom-left, 2 bottom-right,
    /// 3 top-centre, 4 top-left, 5 top-right. The macOS style always sits below the menu bar.
    var position: Int = 0
    /// Where to show: 0 = primary display, 1 = the adjusted TV's screen, 2 = screen under the cursor.
    var monitor: Int = 0
    var timeoutSeconds: Double = 1.6
    var showTvName: Bool = false
    /// Whether the brightness is also written out as a number ("60%") next to the bar.
    var showPercentage: Bool = true
    var showOnSchedule: Bool = false

    enum CodingKeys: String, CodingKey {
        case enabled = "Enabled", style = "Style", position = "Position", monitor = "Monitor"
        case timeoutSeconds = "TimeoutSeconds", showTvName = "ShowTvName", showOnSchedule = "ShowOnSchedule"
        case showPercentage = "ShowPercentage"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        style = try c.decodeIfPresent(Int.self, forKey: .style) ?? 0
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        monitor = try c.decodeIfPresent(Int.self, forKey: .monitor) ?? 0
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 1.6
        showTvName = try c.decodeIfPresent(Bool.self, forKey: .showTvName) ?? false
        showPercentage = try c.decodeIfPresent(Bool.self, forKey: .showPercentage) ?? true
        showOnSchedule = try c.decodeIfPresent(Bool.self, forKey: .showOnSchedule) ?? false
    }
}

/// Rules for automatically turning TVs on and off with the Mac. One set is shared
/// (`AppSettings.power`); a TV can also carry its own (`TvDevice.power`). All opt-in.
struct PowerSettings: Codable, Equatable {
    /// Wake the TVs (WoL) whenever the app starts. With launch-at-login, that's sign-in.
    var onAppStart: Bool = false
    /// Wake the TVs when the Mac wakes from sleep.
    var onResume: Bool = false
    /// Turn the TVs off when the Mac goes to sleep.
    var offOnSleep: Bool = false
    /// Turn the TVs off when the Mac shuts down, restarts or the user logs out.
    var offOnShutdown: Bool = false
    /// React when macOS puts the displays to sleep (idle timer).
    var followDisplayOff: Bool = false
    /// What followDisplayOff does: 0 = screen off (panel blanked, instant resume), 1 = full power off.
    var displayOffAction: Int = 0
    /// Wake the TVs when the displays wake back up.
    var followDisplayOn: Bool = false

    enum CodingKeys: String, CodingKey {
        case onAppStart = "OnAppStart", onResume = "OnResume", offOnSleep = "OffOnSleep"
        case offOnShutdown = "OffOnShutdown", followDisplayOff = "FollowDisplayOff"
        case displayOffAction = "DisplayOffAction", followDisplayOn = "FollowDisplayOn"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onAppStart = try c.decodeIfPresent(Bool.self, forKey: .onAppStart) ?? false
        onResume = try c.decodeIfPresent(Bool.self, forKey: .onResume) ?? false
        offOnSleep = try c.decodeIfPresent(Bool.self, forKey: .offOnSleep) ?? false
        offOnShutdown = try c.decodeIfPresent(Bool.self, forKey: .offOnShutdown) ?? false
        followDisplayOff = try c.decodeIfPresent(Bool.self, forKey: .followDisplayOff) ?? false
        displayOffAction = try c.decodeIfPresent(Int.self, forKey: .displayOffAction) ?? 0
        followDisplayOn = try c.decodeIfPresent(Bool.self, forKey: .followDisplayOn) ?? false
    }
}

/// App-wide preferences. JSON keys match TVControlForWin's settings.json / backup format;
/// "StartWithWindows" is kept as the key for the launch-at-login flag for compatibility.
struct AppSettings: Codable {
    /// How many points the brightness hotkeys nudge per press (1–25).
    var hotkeyStep: Int = 10
    /// Modifier bitmask: 1 = Option (Alt), 2 = Control (Ctrl), 4 = Shift, 8 = Command (Win).
    /// Same values as TVControlForWin's MOD_* mask. Default Control+Option (3).
    var hotkeyModifiers: Int = 3
    /// Which TV the brightness hotkeys change: "" (default) = the TV on the screen under
    /// the cursor, "all" (`RuleTargets.allTvs`) = every TV whose brightness can be set,
    /// otherwise a `TvDevice.id` = always that TV. An id that no longer exists behaves like "".
    var hotkeyTarget: String = ""
    var startAtLogin: Bool = false
    /// How the window opens on an autostart launch: 0 = normal, 1 = minimized,
    /// 2 = no window ("in the background"; on Windows this value means "tray only").
    var launchBehavior: Int = 0
    /// Whether the menu bar icon is shown. The app keeps running without it; relaunching
    /// the app (Dock, Launchpad, Spotlight) is what brings the window back.
    var showMenuBarIcon: Bool = true
    var themeIndex: Int = 0
    var schedules: [BrightnessSchedule] = []
    var applyScheduleOnStartup: Bool = false
    var osd = OsdSettings()
    /// Look on GitHub for a newer version of the app, about once a day.
    var checkForUpdates: Bool = true
    /// Download a newer version when one is found and install it while the window is
    /// closed. Only does anything while `checkForUpdates` is on.
    var installUpdatesAutomatically: Bool = true
    /// When the last update check got an answer, so restarts don't each trigger one.
    var lastUpdateCheckUtc: Date?
    /// The version the last unattended install was for. If the app is still older than
    /// this, that install failed, and it isn't tried again without being asked for.
    var unattendedInstallTried: String?
    /// TV power automation shared by every TV without rules of its own (`TvDevice.power`).
    var power = PowerSettings()

    enum CodingKeys: String, CodingKey {
        case hotkeyStep = "HotkeyStep", hotkeyModifiers = "HotkeyModifiers"
        case hotkeyTarget = "HotkeyTarget"
        case startAtLogin = "StartWithWindows", launchBehavior = "LaunchBehavior"
        case showMenuBarIcon = "ShowMenuBarIcon"
        case themeIndex = "ThemeIndex", schedules = "Schedules"
        case applyScheduleOnStartup = "ApplyScheduleOnStartup"
        case osd = "Osd", power = "Power"
        case checkForUpdates = "CheckForUpdates"
        case installUpdatesAutomatically = "InstallUpdatesAutomatically"
        case lastUpdateCheckUtc = "LastUpdateCheckUtc"
        case unattendedInstallTried = "UnattendedInstallTried"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkeyStep = try c.decodeIfPresent(Int.self, forKey: .hotkeyStep) ?? 10
        hotkeyModifiers = try c.decodeIfPresent(Int.self, forKey: .hotkeyModifiers) ?? 3
        hotkeyTarget = try c.decodeIfPresent(String.self, forKey: .hotkeyTarget) ?? ""
        startAtLogin = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
        launchBehavior = try c.decodeIfPresent(Int.self, forKey: .launchBehavior) ?? 0
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        themeIndex = try c.decodeIfPresent(Int.self, forKey: .themeIndex) ?? 0
        schedules = try c.decodeIfPresent([BrightnessSchedule].self, forKey: .schedules) ?? []
        applyScheduleOnStartup = try c.decodeIfPresent(Bool.self, forKey: .applyScheduleOnStartup) ?? false
        osd = try c.decodeIfPresent(OsdSettings.self, forKey: .osd) ?? OsdSettings()
        power = try c.decodeIfPresent(PowerSettings.self, forKey: .power) ?? PowerSettings()
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? true
        installUpdatesAutomatically = try c.decodeIfPresent(Bool.self, forKey: .installUpdatesAutomatically) ?? true
        // Written by either app as an ISO-8601 string; one that can't be read is treated
        // as "never checked", which only costs an extra check.
        lastUpdateCheckUtc = (try? c.decodeIfPresent(String.self, forKey: .lastUpdateCheckUtc))
            .flatMap { $0 }.flatMap(Self.parseDate)
        unattendedInstallTried = try? c.decodeIfPresent(String.self, forKey: .unattendedInstallTried)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hotkeyStep, forKey: .hotkeyStep)
        try c.encode(hotkeyModifiers, forKey: .hotkeyModifiers)
        try c.encode(hotkeyTarget, forKey: .hotkeyTarget)
        try c.encode(startAtLogin, forKey: .startAtLogin)
        try c.encode(launchBehavior, forKey: .launchBehavior)
        try c.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try c.encode(themeIndex, forKey: .themeIndex)
        try c.encode(schedules, forKey: .schedules)
        try c.encode(applyScheduleOnStartup, forKey: .applyScheduleOnStartup)
        try c.encode(osd, forKey: .osd)
        try c.encode(power, forKey: .power)
        try c.encode(checkForUpdates, forKey: .checkForUpdates)
        try c.encode(installUpdatesAutomatically, forKey: .installUpdatesAutomatically)
        try c.encodeIfPresent(lastUpdateCheckUtc.map(Self.formatDate), forKey: .lastUpdateCheckUtc)
        try c.encodeIfPresent(unattendedInstallTried, forKey: .unattendedInstallTried)
    }

    // .NET writes up to seven fractional digits ("2026-11-26T18:29:10.1234567Z"), which
    // ISO8601DateFormatter doesn't accept, so the fraction is cut off before parsing.
    private static func parseDate(_ text: String) -> Date? {
        var trimmed = text
        if let dot = trimmed.firstIndex(of: ".") {
            let tail = trimmed[dot...].drop { $0 == "." || $0.isNumber }
            trimmed = String(trimmed[..<dot]) + (tail.isEmpty ? "Z" : String(tail))
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    private static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// A single-file backup bundling all TVs and app settings (TVControlForWin-compatible).
struct BackupData: Codable {
    var devices: [TvDevice]?
    var settings: AppSettings?

    enum CodingKeys: String, CodingKey {
        case devices = "Devices", settings = "Settings"
    }
}
