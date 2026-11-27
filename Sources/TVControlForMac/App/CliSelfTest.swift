// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// `--selftest`: offline checks of the pure logic (rule targeting, settings files in
/// TVControlForWin's format). Prints PASS/FAIL per check; exits non-zero on a failure.
enum SelfTestCli {
    static let commands: Set<String> = ["--selftest"]

    private static var failures = 0

    private static func check(_ name: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL")  \(name)")
        if !condition { failures += 1 }
    }

    static func run(_ args: [String]) async {
        schedules()
        power()
        hotkeys()
        files()
        legacyFiles()
        interop()
        print(failures == 0 ? "All checks passed." : "\(failures) check(s) FAILED.")
        if failures > 0 { exit(1) }
    }

    private static func schedule(_ hour: Int, _ minute: Int, _ brightness: Int,
                                 tvs: [String] = [], enabled: Bool = true) -> BrightnessSchedule {
        var s = BrightnessSchedule()
        s.hour = hour; s.minute = minute; s.brightness = brightness; s.tvIds = tvs; s.enabled = enabled
        return s
    }

    private static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private static func schedules() {
        let morning = schedule(8, 0, 70), night = schedule(21, 30, 30, tvs: ["a"])
        let off = schedule(12, 0, 99, enabled: false)
        let all = [morning, night, off]

        check("schedule: empty list targets every TV", RuleTargets.targets(morning, tvId: "b"))
        check("schedule: a named list targets only those TVs",
              RuleTargets.targets(night, tvId: "a") && !RuleTargets.targets(night, tvId: "b"))
        check("schedule: in effect is the latest one passed",
              RuleTargets.scheduledBrightness(all, tvId: "a", now: date(27, 22, 0)) == 30)
        check("schedule: a TV not named falls back to its own latest",
              RuleTargets.scheduledBrightness(all, tvId: "b", now: date(27, 22, 0)) == 70)
        check("schedule: before the first of the day wraps to last night's",
              RuleTargets.scheduledBrightness(all, tvId: "a", now: date(27, 6, 0)) == 30)
        check("schedule: disabled ones are ignored",
              RuleTargets.scheduledBrightness([off], tvId: "a", now: date(27, 13, 0)) == nil)
        check("schedule: same time, later in the list wins",
              RuleTargets.inEffect([schedule(8, 0, 10), schedule(8, 0, 20)], nowMinutes: 600)?.brightness == 20)

        check("catch-up: a gap containing a schedule fires",
              RuleTargets.anyFires(all, between: date(27, 7, 0), and: date(27, 9, 0)))
        check("catch-up: a gap containing none doesn't",
              !RuleTargets.anyFires(all, between: date(27, 9, 0), and: date(27, 11, 0)))
        check("catch-up: a gap across midnight sees the morning one",
              RuleTargets.anyFires([morning], between: date(26, 23, 0), and: date(27, 8, 0)))
        check("catch-up: a day or more means every schedule fired",
              RuleTargets.anyFires([morning], between: date(25, 9, 0), and: date(26, 9, 30)))
        check("catch-up: the gap is (from, to]: ending on a schedule's minute counts, starting on it doesn't",
              RuleTargets.anyFires([morning], between: date(27, 7, 0), and: date(27, 8, 0))
              && !RuleTargets.anyFires([morning], between: date(27, 8, 0), and: date(27, 9, 0)))
        // Ticks 61 s apart can straddle a whole minute (07:59:59.5 → 08:01:00.5): such a gap
        // has to be one the service checks.
        let straddle = date(27, 7, 59).addingTimeInterval(59.5)
        check("catch-up: a 61 s pause over a schedule's whole minute is caught",
              straddle.addingTimeInterval(61).timeIntervalSince(straddle) > ScheduleService.gapThreshold
              && RuleTargets.anyFires([morning], between: straddle, and: straddle.addingTimeInterval(61)))
        check("catch-up: a TV isn't touched because of another TV's schedule",
              RuleTargets.catchUpBrightness(all, tvId: "b", from: date(27, 21, 0), to: date(27, 22, 0)) == nil)
        check("catch-up: the TV it targets gets the value now in effect",
              RuleTargets.catchUpBrightness(all, tvId: "a", from: date(27, 21, 0), to: date(27, 22, 0)) == 30)

        check("picker: ticking adds, un-ticking removes, All clears",
              RuleTargets.toggleTarget([], tvId: "a") == ["a"]
              && RuleTargets.toggleTarget(["a", "b"], tvId: "a") == ["b"]
              && RuleTargets.toggleTarget(["a"], tvId: nil) == [])
        let infos = [TvInfo(id: "a", name: "Desk", supportsBrightness: true, pairedScreenId: "s1"),
                     TvInfo(id: "b", name: "Studio", supportsBrightness: true, pairedScreenId: "s2")]
        check("picker: labels",
              RuleTargets.targetLabel([], tvs: infos) == "All TVs"
              && RuleTargets.targetLabel(["b"], tvs: infos) == "Studio"
              && RuleTargets.targetLabel(["a", "b"], tvs: infos) == "2 TVs"
              && RuleTargets.targetLabel(["gone"], tvs: infos) == "No TVs")

        var named = schedule(9, 0, 40, tvs: ["a"])
        let changed = RuleTargets.forgetTv(&named, removedId: "a", remainingIds: ["b"])
        check("removing a schedule's only TV switches it off rather than widening it",
              changed && named.tvIds.isEmpty && !named.enabled)
        var forAll = schedule(9, 0, 40)
        check("removing a TV leaves an all-TVs schedule alone",
              !RuleTargets.forgetTv(&forAll, removedId: "a", remainingIds: ["b"]) && forAll.enabled)
    }

    private static func power() {
        var shared = PowerSettings()
        shared.offOnSleep = true
        shared.followDisplayOff = true
        var own = PowerSettings()
        own.onResume = true
        own.followDisplayOff = true
        own.displayOffAction = 1

        check("power: display off blanks by default, turns off when chosen",
              RuleTargets.action(for: .displayOff, rules: shared) == .screenOff
              && RuleTargets.action(for: .displayOff, rules: own) == .turnOff)
        check("power: a rule that's off does nothing",
              RuleTargets.action(for: .appStart, rules: shared) == .none)

        let tvs: [(id: String, own: PowerSettings?)] = [("a", nil), ("b", own)]
        let sleep = RuleTargets.planPowerEvent(.suspend, tvs: tvs, ownRules: { $0.own }, shared: shared)
        check("power: a TV with its own rules ignores the shared ones",
              sleep.count == 1 && sleep[0].tv.id == "a" && sleep[0].action == .turnOff)
        let wake = RuleTargets.planPowerEvent(.resume, tvs: tvs, ownRules: { $0.own }, shared: shared)
        check("power: and follows its own", wake.count == 1 && wake[0].tv.id == "b" && wake[0].action == .powerOn)
    }

    private static func hotkeys() {
        let lg = TvInfo(id: "a", name: "Desk", supportsBrightness: true, pairedScreenId: "s1")
        let tcl = TvInfo(id: "b", name: "Studio", supportsBrightness: true, pairedScreenId: "s2")
        let powerOnly = TvInfo(id: "c", name: "Sony", supportsBrightness: false, pairedScreenId: "s3")

        func plan(_ target: String, _ tvs: [TvInfo], cursor: String?) -> HotkeyPlan {
            RuleTargets.planHotkey(target: target, tvs: tvs, cursorScreen: { cursor })
        }

        check("hotkey: one TV is always the target", plan("", [lg], cursor: "elsewhere") == .adjust(["a"], shown: "a"))
        check("hotkey: several TVs, the one under the cursor",
              plan("", [lg, tcl], cursor: "s2") == .adjust(["b"], shown: "b"))
        check("hotkey: several TVs, cursor on no TV's display asks to link",
              plan("", [lg, tcl], cursor: "s9") == .unpaired)
        check("hotkey: cursor on a power-only TV does nothing",
              plan("", [lg, powerOnly], cursor: "s3") == .nothing)
        check("hotkey: one dimmable TV among several is the target elsewhere",
              plan("", [lg, powerOnly], cursor: "s9") == .adjust(["a"], shown: "a"))
        check("hotkey: all TVs moves every dimmable one, shows the one under the cursor",
              plan("all", [lg, tcl, powerOnly], cursor: "s2") == .adjust(["a", "b"], shown: "b"))
        check("hotkey: all TVs with the cursor on a power-only TV shows the first dimmable",
              plan("all", [lg, tcl, powerOnly], cursor: "s3") == .adjust(["a", "b"], shown: "a"))
        check("hotkey: a fixed TV wherever the cursor is",
              plan("b", [lg, tcl], cursor: "s1") == .adjust(["b"], shown: "b"))
        check("hotkey: a fixed TV that can't be dimmed does nothing", plan("c", [lg, powerOnly], cursor: "s1") == .nothing)
        check("hotkey: a fixed TV that's gone falls back to the cursor",
              plan("gone", [lg, tcl], cursor: "s1") == .adjust(["a"], shown: "a"))
        check("hotkey: nothing dimmable, nothing happens", plan("all", [powerOnly], cursor: nil) == .nothing)
    }

    // Files as TVControlForWin 3.0 writes them (System.Text.Json: nulls written out, seven
    // fractional digits on dates, keys this app doesn't know).
    private static func files() {
        let devices = """
        [ { "Id": "0f8fad5bd9cb469fa16570867728950e", "Name": "Desk OLED", "Host": "192.168.1.159",
            "Kind": 0, "ClientKey": "abc", "ClientCertificate": "", "AdbKey": "", "LastBacklight": 60,
            "PairedScreenId": "", "Secure": true, "MacAddress": "AA:BB:CC:DD:EE:FF", "Power": null },
          { "Id": "7c9e6679742540de944be07fc1f90ae7", "Name": "Studio TV", "Host": "192.168.1.154",
            "Kind": 1, "ClientKey": "", "ClientCertificate": "MIIB", "AdbKey": "MIIE", "LastBacklight": 60,
            "PairedScreenId": "", "Secure": false, "MacAddress": "",
            "Power": { "OnAppStart": true, "OnResume": false, "OffOnSleep": true, "OffOnShutdown": false,
                       "FollowDisplayOff": true, "DisplayOffAction": 1, "FollowDisplayOn": false } },
          { "Name": "Old entry", "Host": "10.0.0.2", "ClientKey": "k" } ]
        """
        let settings = """
        { "HotkeyStep": 5, "HotkeyModifiers": 3, "HotkeyTarget": "all", "StartWithWindows": true,
          "LaunchBehavior": 2, "WindowWidth": 1200, "WindowHeight": 900, "ThemeIndex": 2,
          "Schedules": [ { "Hour": 8, "Minute": 0, "Brightness": 70, "Enabled": true,
                           "TvIds": ["7c9e6679742540de944be07fc1f90ae7"] },
                         { "Hour": 22, "Minute": 15, "Brightness": 20, "Enabled": false } ],
          "ApplyScheduleOnStartup": true,
          "Osd": { "Enabled": true, "Position": 3, "Monitor": 1, "TimeoutSeconds": 2.5,
                   "ShowTvName": true, "ShowOnSchedule": false },
          "CheckForUpdates": false, "InstallUpdatesAutomatically": true,
          "LastUpdateCheckUtc": "2026-11-26T18:29:10.1234567Z", "UnattendedInstallTried": null,
          "Power": { "OnAppStart": false, "OnResume": true, "OffOnSleep": true, "OffOnShutdown": true,
                     "FollowDisplayOff": false, "DisplayOffAction": 0, "FollowDisplayOn": false } }
        """

        guard let tvs = try? JSONDecoder().decode([TvDevice].self, from: Data(devices.utf8)) else {
            check("files: a TVControlForWin devices.json loads", false)
            return
        }
        check("files: a TVControlForWin devices.json loads", tvs.count == 3)
        check("files: kinds, credentials and ids carry over",
              tvs[0].kind == .webOs && tvs[0].clientKey == "abc" && tvs[0].secure
              && tvs[1].kind == .androidTv && tvs[1].clientCertificate == "MIIB" && tvs[1].adbKey == "MIIE"
              && tvs[1].id == "7c9e6679742540de944be07fc1f90ae7")
        check("files: a TV's own power rules load, null means shared",
              tvs[0].power == nil && tvs[1].power?.displayOffAction == 1 && tvs[1].power?.onAppStart == true)
        check("files: an entry from before ids existed gets one, and says so",
              !tvs[2].id.isEmpty && tvs[2].idWasAssigned && !tvs[0].idWasAssigned && tvs[2].kind == .webOs)

        guard let loaded = try? JSONDecoder().decode(AppSettings.self, from: Data(settings.utf8)) else {
            check("files: a TVControlForWin settings.json loads", false)
            return
        }
        check("files: a TVControlForWin settings.json loads",
              loaded.hotkeyStep == 5 && loaded.hotkeyTarget == "all" && loaded.startAtLogin
              && loaded.launchBehavior == 2 && loaded.themeIndex == 2 && loaded.osd.position == 3
              && loaded.power.onResume && !loaded.checkForUpdates && loaded.unattendedInstallTried == nil)
        check("files: schedule targets load, a missing list means all TVs",
              loaded.schedules.count == 2 && loaded.schedules[0].tvIds.count == 1 && loaded.schedules[1].tvIds.isEmpty)
        let expected = ISO8601DateFormatter().date(from: "2026-11-26T18:29:10Z")
        check("files: a .NET timestamp with seven fractional digits is read",
              loaded.lastUpdateCheckUtc != nil && loaded.lastUpdateCheckUtc == expected)

        // What this app writes must load again unchanged.
        let store = DeviceStore()
        let backup = store.serializeBackup(devices: tvs, settings: loaded)
        let again = try? store.deserializeBackup(backup)
        check("files: a backup round-trips",
              again?.devices?.count == 3 && again?.devices?[1].power == tvs[1].power
              && again?.devices?[2].id == tvs[2].id && again?.settings?.hotkeyTarget == "all"
              && again?.settings?.schedules.first?.tvIds == loaded.schedules.first?.tvIds
              && again?.settings?.lastUpdateCheckUtc == expected)
        check("files: something that isn't a backup is refused",
              (try? store.deserializeBackup("[1, 2, 3]")) == nil)
        // Importing replaces every TV and setting, so a JSON file picked by mistake (any
        // object with neither "Devices" nor "Settings") must not count as an empty backup.
        check("files: a JSON object with neither Devices nor Settings is refused",
              (try? store.deserializeBackup(#"{ "name": "something else", "version": 1 }"#)) == nil)
        // Every real backup has both sections; one without the TVs would remove them all.
        check("files: a settings-only file is refused",
              (try? store.deserializeBackup(#"{ "Settings": { "HotkeyStep": 5 } }"#)) == nil)
        check("files: a devices-only file is refused",
              (try? store.deserializeBackup(#"{ "Devices": [] }"#)) == nil)
        check("files: a backup with no TVs in it still imports",
              (try? store.deserializeBackup(#"{ "Devices": [], "Settings": {} }"#))?.devices?.isEmpty == true)
    }

    // Files as LGforMac 1.0 wrote them: what the first launch after the rename copies over
    // from ~/Library/Application Support/LGforMac. No ids, no kinds, no schedule targets.
    private static func legacyFiles() {
        let devices = """
        [ { "Name": "Desk OLED", "Host": "192.168.1.159", "ClientKey": "k1", "LastBacklight": 35,
            "PairedScreenId": "37D8832A-2D66-02CA-B9F7-8F30A301B230", "PairedScreenName": "LG TV SSCR2",
            "AutomationOnlyWhenConnected": true, "LastDisplayConnected": false,
            "Secure": true, "MacAddress": "AA:BB:CC:DD:EE:FF,11:22:33:44:55:66" } ]
        """
        let settings = """
        { "HotkeyStep": 7, "HotkeyModifiers": 9, "StartWithWindows": true, "LaunchBehavior": 2,
          "ShowMenuBarIcon": false, "ThemeIndex": 1,
          "Schedules": [ { "Hour": 21, "Minute": 0, "Brightness": 20, "Enabled": true } ],
          "ApplyScheduleOnStartup": true,
          "Osd": { "Enabled": true, "Style": 1, "Position": 5, "Monitor": 2, "TimeoutSeconds": 3,
                   "ShowTvName": true, "ShowOnSchedule": true },
          "Power": { "OnAppStart": true, "OnResume": true, "OffOnSleep": true, "OffOnShutdown": false,
                     "FollowDisplayOff": true, "DisplayOffAction": 1, "FollowDisplayOn": true } }
        """

        let tv = (try? JSONDecoder().decode([TvDevice].self, from: Data(devices.utf8)))?.first
        check("legacy: an LGforMac 1.0 devices.json loads as an LG with a new id",
              tv?.kind == .webOs && tv?.idWasAssigned == true && !(tv?.id.isEmpty ?? true) && tv?.power == nil)
        check("legacy: pairing, wake and display link carry over",
              tv?.clientKey == "k1" && tv?.secure == true && tv?.macAddress == "AA:BB:CC:DD:EE:FF,11:22:33:44:55:66"
              && tv?.lastBacklight == 35 && tv?.pairedScreenName == "LG TV SSCR2")
        check("legacy: \"Automate only while connected\" and its presence snapshot carry over",
              tv?.automationOnlyWhenConnected == true && tv?.lastDisplayConnected == false)

        let s = try? JSONDecoder().decode(AppSettings.self, from: Data(settings.utf8))
        check("legacy: an LGforMac 1.0 settings.json loads",
              s?.hotkeyStep == 7 && s?.hotkeyModifiers == 9 && s?.startAtLogin == true
              && s?.launchBehavior == 2 && s?.showMenuBarIcon == false && s?.applyScheduleOnStartup == true)
        check("legacy: old schedules apply to all TVs, the hotkey follows the pointer",
              s?.schedules.count == 1 && s?.schedules.first?.tvIds.isEmpty == true && s?.hotkeyTarget == "")
        check("legacy: OSD style and a whole-number duration load",
              s?.osd.style == 1 && s?.osd.timeoutSeconds == 3.0 && s?.osd.position == 5)
        check("legacy: shared power rules load, updates default to on",
              s?.power.offOnSleep == true && s?.power.displayOffAction == 1
              && s?.checkForUpdates == true && s?.installUpdatesAutomatically == true && s?.lastUpdateCheckUtc == nil)
    }

    // What this app writes has to be readable by TVControlForWin (System.Text.Json: keys are
    // case-sensitive, enums are numbers, DateTime wants ISO 8601), and what it reads has to
    // cover what .NET can write.
    private static func interop() {
        let expected = ISO8601DateFormatter().date(from: "2026-11-26T18:29:10Z")
        let dates: [(String, String)] = [
            ("no fraction", "2026-11-26T18:29:10Z"),
            ("an offset", "2026-11-26T20:29:10+02:00"),
            ("a fraction and an offset", "2026-11-26T20:29:10.1234567+02:00"),
        ]
        for (what, text) in dates {
            let json = #"{ "LastUpdateCheckUtc": "\#(text)" }"#
            let loaded = try? JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            check("interop: a timestamp with \(what) is read", loaded?.lastUpdateCheckUtc == expected)
        }

        let nulls = #"[ { "Id": "abc", "Name": null, "Host": "10.0.0.3", "Kind": 1, "PairedScreenId": null, "Power": null } ]"#
        let tv = (try? JSONDecoder().decode([TvDevice].self, from: Data(nulls.utf8)))?.first
        check("interop: explicit nulls load as defaults",
              tv?.name == "Google TV" && tv?.pairedScreenId == "" && tv?.power == nil && tv?.kind == .androidTv)

        var settings = AppSettings()
        settings.lastUpdateCheckUtc = expected
        var schedule = BrightnessSchedule()
        schedule.tvIds = ["abc"]
        settings.schedules = [schedule]
        let device = TvDevice(name: "Studio", host: "10.0.0.3", kind: .androidTv)
        let backup = DeviceStore().serializeBackup(devices: [device], settings: settings)
        let root = (try? JSONSerialization.jsonObject(with: Data(backup.utf8))) as? [String: Any]
        let written = root?["Settings"] as? [String: Any]
        let writtenTv = (root?["Devices"] as? [[String: Any]])?.first
        let stamp = written?["LastUpdateCheckUtc"] as? String ?? ""
        check("interop: the backup uses TVControlForWin's top-level and settings keys",
              written?["StartWithWindows"] is Bool && written?["HotkeyTarget"] is String
              && ((written?["Schedules"] as? [[String: Any]])?.first?["TvIds"] as? [String]) == ["abc"])
        check("interop: a TV's kind is written as a number, its id as a string",
              (writtenTv?["Kind"] as? NSNumber)?.intValue == 1 && writtenTv?["Id"] as? String == device.id)
        check("interop: the update timestamp is written the way .NET reads it",
              stamp.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression) != nil)
    }
}
