// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Network
import Observation

/// Outcome of a brightness hotkey: TVs were adjusted, no linked TV was under the cursor
/// (prompt to link), the TV it would have changed is paused because its linked display
/// is unplugged, or there was nothing to adjust.
enum HotkeyOutcome {
    /// `name` is set only when a single TV changed.
    case adjusted(name: String?, value: Int, screenId: String?)
    case unpaired
    case disconnected
    case none
}

/// One entry in a TV chooser (Power page, Hotkeys page): a TV by its id, or a special
/// entry such as "All TVs" with an id that no TV has.
struct TvChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Top-level app state: TVs, schedules, settings and hotkey routing, shared by the main
/// window, the menu bar extra and the background services (TVControlForWin's MainViewModel).
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    private let store = DeviceStore()

    var settings: AppSettings
    var tvs: [TvState] = []
    /// Connected displays, for linking each TV to the screen it drives. Refreshed on demand.
    var screens: [ScreenInfo] = []
    /// The page the main window shows.
    var page: AppPage = .home

    /// True when a downloaded update is waiting for the user (the dot on Settings).
    var updateReady: Bool { false }

    // Background services (started once from the app delegate).
    @ObservationIgnored let hotkeys = HotkeyService()
    @ObservationIgnored let scheduleService = ScheduleService()
    @ObservationIgnored let powerEvents = PowerEventService()
    @ObservationIgnored let osd = OsdController()

    private init() {
        settings = store.loadSettings()
        for device in store.loadDevices() {
            add(device, start: false)
        }
        saveAssignedIds()
        refreshScreens()
    }

    /// Wires services and kicks off connections. Called once at launch.
    /// - Parameter afterUpdate: the app is coming back from installing an update rather
    ///   than being started by the user or at login.
    func start(afterUpdate: Bool = false) {
        for tv in tvs { tv.start() }

        AutostartService.apply(settings.startAtLogin)
        applyTheme()

        hotkeys.onHotkey = { [weak self] action in
            guard let self else { return }
            let step = self.settings.hotkeyStep
            self.handleHotkey(step: action == .brightnessUp ? step : -step)
        }
        hotkeys.start(modifiers: settings.hotkeyModifiers)

        scheduleService.getSchedules = { [weak self] in self?.settings.schedules ?? [] }
        scheduleService.onFire = { [weak self] schedule in
            guard let self else { return }
            self.showScheduleOsd(self.applySchedule(schedule))
        }
        scheduleService.onCatchUp = { [weak self] from, to in
            guard let self else { return }
            self.showScheduleOsd(self.catchUpSchedules(from: from, to: to))
        }
        scheduleService.start()

        // Order matters: the on-app-start wake decision must read the persisted display
        // presence from the previous session, BEFORE live tracking overwrites it (a TV
        // that's off has no HDMI link, so a live sample would always say "absent").
        wirePowerAutomation(afterUpdate: afterUpdate)
        startDisplayTracking()

        // Hidden test/debug hook: `--osd-preview` posts this distributed notification so
        // the OSD can be exercised without clicking through the UI.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("\(AppInfo.bundleIdentifier).osd-preview"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppState.shared.previewOsd() }
        }
    }

    // MARK: - Local Network permission

    /// True after repeated unreachable-TV connect cycles. The usual cause on macOS is the
    /// Local Network permission being denied, so the UI shows a hint with a settings link.
    var networkPermissionSuspected = false
    @ObservationIgnored private var consecutiveConnectFailures = 0
    @ObservationIgnored private var promptRetriggered = false

    func noteConnectOutcome(success: Bool) {
        if success {
            consecutiveConnectFailures = 0
            networkPermissionSuspected = false
        } else {
            consecutiveConnectFailures += 1
            if consecutiveConnectFailures >= 3, !networkPermissionSuspected {
                networkPermissionSuspected = true
                // Once per launch, nudge macOS to show the Local Network prompt itself;
                // a multicast is what reliably makes the system (re)register the app.
                if !promptRetriggered {
                    promptRetriggered = true
                    requestLocalNetworkAccess()
                }
            }
        }
    }

    /// Opens System Settings at Privacy & Security; the app needs its Network (macOS 26+)
    /// and/or Local Network toggles enabled there.
    func openLocalNetworkSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        NSWorkspace.shared.open(pane)
    }

    @ObservationIgnored private var permissionProbes: [Any] = []

    /// Nudges macOS to (re)show the Local Network permission prompt. Uses several paths
    /// because registration is flaky on recent macOS: an SSDP multicast burst, a Bonjour
    /// browse, and a direct Network.framework connection to the first TV. NWBrowser /
    /// NWConnection go through the local-network privacy machinery explicitly.
    func requestLocalNetworkAccess() {
        Task { _ = await SsdpDiscovery.findTvs(timeout: 2) }

        let browser = NWBrowser(for: .bonjour(type: "_airplay._tcp", domain: nil), using: .init())
        browser.start(queue: .global())
        permissionProbes.append(browser)

        if let tv = tvs.first {
            let port: NWEndpoint.Port = tv.device.kind == .androidTv
                ? NWEndpoint.Port(rawValue: TvControllerFactory.androidTvRemotePort)! : 3000
            let connection = NWConnection(host: NWEndpoint.Host(tv.host), port: port, using: .tcp)
            connection.start(queue: .global())
            permissionProbes.append(connection)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            for probe in self.permissionProbes {
                (probe as? NWBrowser)?.cancel()
                (probe as? NWConnection)?.cancel()
            }
            self.permissionProbes.removeAll()
        }
    }

    // MARK: - Display presence (linked-display automation gate)

    // Presence is only trustworthy while the Mac is awake with its displays on: a TV we
    // just turned off drops its HDMI link, and recording that "absence" during sleep or
    // display-sleep would wrongly block the matching wake rule later.
    @ObservationIgnored private var systemAwake = true
    @ObservationIgnored private var displaysOn = true
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    private func startDisplayTracking() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                AppState.shared.refreshScreens()
                AppState.shared.updateDisplayPresence()
            }
        }
        refreshScreens()
        updateDisplayPresence()
    }

    /// Re-samples which linked displays are present and persists changes. No-op while
    /// the Mac is asleep or its displays are off (see above). Applies a schedule that
    /// was missed while a TV's display was unplugged as soon as it returns.
    func updateDisplayPresence() {
        guard systemAwake, displaysOn else { return }
        var devicesChanged = false

        for tv in tvs {
            guard !tv.linkedScreenId.isEmpty else {
                if !tv.displayConnected { tv.displayConnected = true } // unlinked TVs never gate
                continue
            }
            let screen = screens.first { $0.id == tv.linkedScreenId }
            let present = screen != nil

            if let screen, tv.linkedScreenName != screen.name {
                tv.refreshLinkName(screen.name)
                devicesChanged = true
            }
            if tv.displayConnected != present {
                tv.displayConnected = present
                Log.write("\(tv.host): linked display \(present ? "connected" : "disconnected")")
            }
            if tv.device.lastDisplayConnected != present {
                tv.device.lastDisplayConnected = present
                devicesChanged = true
            }
            if present, tv.missedScheduleWhileDisconnected {
                tv.missedScheduleWhileDisconnected = false
                if tv.acceptsBrightness,
                   let value = RuleTargets.scheduledBrightness(settings.schedules, tvId: tv.id) {
                    Log.write("\(tv.host): display is back, applying scheduled \(value)%")
                    tv.applyBrightness(value)
                }
            }
        }

        if devicesChanged { persist() }
    }

    /// Links a TV to a display (or unlinks with an empty id) and re-samples presence.
    func linkDisplay(_ tv: TvState, screenId: String) {
        guard screenId != tv.linkedScreenId else { return }
        let name = screens.first { $0.id == screenId }?.name ?? ""
        tv.setLink(screenId: screenId, name: name)
        persist()
        updateDisplayPresence()
    }

    // MARK: - Power automation (Power page rules)
    //
    // Each TV follows its own rules (TvDevice.power) when it has them, otherwise the
    // shared ones (settings.power). A TV whose automation is paused (linked display not
    // connected) sits every event out.

    private func wirePowerAutomation(afterUpdate: Bool) {
        // Sleep and shutdown give handlers only moments: send the off commands over the
        // already-open connections and wait briefly, then let go.
        powerEvents.onSuspending = { [weak self] in
            guard let self else { return }
            self.systemAwake = false // presence is frozen until the Mac is back
            self.applyPowerEvent(.suspend, waitingUpTo: 1.5)
        }
        powerEvents.onSessionEnding = { [weak self] in
            guard let self else { return }
            self.systemAwake = false
            self.applyPowerEvent(.sessionEnding, waitingUpTo: 2.0)
        }
        powerEvents.onResumed = { [weak self] in
            guard let self else { return }
            self.systemAwake = true
            self.applyPowerEvent(.resume) // decided from presence as of falling asleep
            self.updateDisplayPresence()
        }
        powerEvents.onDisplayStateChanged = { [weak self] on in
            guard let self else { return }
            if !on {
                self.displaysOn = false // freeze presence before the TVs power down
                self.applyPowerEvent(.displayOff)
            } else {
                self.displaysOn = true
                self.applyPowerEvent(.displayOn) // before re-sampling: a woken TV isn't back on HDMI yet
                self.refreshScreens()
                self.updateDisplayPresence()
            }
        }

        // "Turn on when the app starts": the app just started, so wake the TVs now. WoL
        // reaches TVs that are off; ones already on simply ignore it. Not after an update:
        // the app only blinked, and a TV someone switched off in the meantime should stay off.
        if !afterUpdate {
            applyPowerEvent(.appStart)
        }
    }

    /// Carries out the power rules for one Mac power event. With `waitingUpTo`, blocks the
    /// calling (main) thread that long at most, so the commands make it onto the wire
    /// before the system finishes sleeping or logging out; the sends themselves run off
    /// the main thread.
    private func applyPowerEvent(_ event: MacPowerEvent, waitingUpTo timeout: TimeInterval? = nil) {
        let plan = RuleTargets.planPowerEvent(event, tvs: tvs, ownRules: { $0.device.power },
                                              shared: settings.power)
            .filter { entry in
                if entry.tv.automationAllowed { return true }
                Log.write("\(entry.tv.host): \(event.rawValue) skipped, linked display not connected")
                return false
            }
        guard !plan.isEmpty else { return }

        Log.write("power: \(event.rawValue) -> "
                  + plan.map { "\($0.tv.name): \($0.action.rawValue)" }.joined(separator: ", "))

        let commands = plan.map { (controller: $0.tv.controller, action: $0.action) }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for command in commands {
                    group.addTask {
                        switch command.action {
                        case .turnOff: await command.controller.turnOff()
                        // Blanks the panel (webOS keeps running, resume is instant); TVs that
                        // can't blank just the panel go to standby instead.
                        case .screenOff: await command.controller.screenOff()
                        // Un-blanks connected TVs, wakes the rest.
                        case .powerOn: await command.controller.powerOn()
                        case .none: break
                        }
                    }
                }
            }
            done.signal()
        }
        if let timeout {
            _ = done.wait(timeout: .now() + timeout)
        }
    }

    // MARK: - Power page: whose rules are shown

    /// "All TVs" (the shared rules, id "") and each TV by name.
    var powerScopes: [TvChoice] {
        [TvChoice(id: "", name: "All TVs")] + tvs.map { TvChoice(id: $0.id, name: $0.name) }
    }

    /// The chooser shows with more than one TV. With a single TV it stays visible only if
    /// that TV still has rules of its own (left over from when there were more), so they
    /// can be undone.
    var showsPowerScope: Bool {
        tvs.count > 1 || tvs.contains { $0.ownPower != nil }
    }

    /// The rules a scope shows: the TV's own when it has them, otherwise the shared ones.
    func powerRules(scope tvId: String) -> PowerSettings {
        tv(withId: tvId)?.ownPower ?? settings.power
    }

    /// False while a TV that follows the shared rules is selected: the controls then show
    /// the shared rules without changing them.
    func powerRulesEditable(scope tvId: String) -> Bool {
        guard let tv = tv(withId: tvId) else { return true }
        return tv.ownPower != nil
    }

    func setPowerRules(_ rules: PowerSettings, scope tvId: String) {
        if let tv = tv(withId: tvId) {
            guard tv.ownPower != nil else { return }
            tv.ownPower = rules
        } else {
            settings.power = rules
            saveSettings()
        }
    }

    /// Switching separate rules on starts them as a copy of the shared rules; switching
    /// them off discards them, so the TV follows the shared rules again.
    func setSeparatePowerRules(_ separate: Bool, for tv: TvState) {
        guard separate != (tv.ownPower != nil) else { return }
        tv.ownPower = separate ? settings.power : nil
    }

    // MARK: - TVs

    func tv(withId id: String) -> TvState? {
        id.isEmpty ? nil : tvs.first { $0.id == id }
    }

    /// The TVs as rule targeting sees them right now.
    var tvInfos: [TvInfo] { tvs.map(\.info) }

    /// True when a TV with this host/IP is already in the list (used by discovery).
    func hasTv(host: String) -> Bool {
        tvs.contains { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    /// Adds a TV by address. Which protocol it speaks is worked out from the ports it
    /// answers on, so there's no brand to pick. Returns nil when it was added, otherwise
    /// what to tell the user.
    func addTv(name: String, host: String) async -> String? {
        let host = host.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        if hasTv(host: host) { return "That TV is already added" }

        guard let kind = await TvControllerFactory.detectKind(host: host) else {
            // Nothing answered, so there's no telling what kind of TV it is. Better to say
            // so than to save a card that could never connect.
            return "No TV found at that address. Turn the TV on and try again"
        }
        if hasTv(host: host) { return nil } // added some other way while we were probing

        add(TvDevice(name: name.isEmpty ? kind.defaultName : name, host: host, kind: kind),
            start: true, pair: true)
        persist()
        return nil
    }

    /// Adds a TV found by network discovery (no-op if its IP is already added).
    func addDiscoveredTv(_ tv: DiscoveredTv) {
        guard !hasTv(host: tv.host) else { return }
        add(TvDevice(name: tv.name, host: tv.host, kind: tv.kind), start: true, pair: true)
        persist()
    }

    func removeTv(_ tv: TvState) {
        guard let index = tvs.firstIndex(where: { $0 === tv }) else { return }
        tvs.remove(at: index)
        tv.dispose()
        persist()
        forgetTvInRules(tv.id)
    }

    // A removed TV's own power rules go with its device entry; schedules and the hotkey
    // target name it by id and are cleaned up here.
    private func forgetTvInRules(_ tvId: String) {
        let remaining = tvs.map(\.id)
        var changed = false
        for index in settings.schedules.indices {
            if RuleTargets.forgetTv(&settings.schedules[index], removedId: tvId, remainingIds: remaining) {
                changed = true
            }
        }
        if settings.hotkeyTarget == tvId {
            settings.hotkeyTarget = ""
            changed = true
        }
        if changed { saveSettings() }
    }

    func moveTvs(from source: IndexSet, to destination: Int) {
        tvs.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // `pair` is set when the user has just added the TV: they're at the Mac and expecting
    // it, so a TV that pairs by on-screen code may show that code straight away. A TV
    // loaded from disk unpaired waits for the Pair button instead.
    private func add(_ device: TvDevice, start: Bool, pair: Bool = false) {
        let tv = TvState(device: device, persist: { [weak self] in self?.persist() },
                         startupBrightness: { [weak self] in
                             DispatchQueue.main.sync {
                                 MainActor.assumeIsolated { self?.startupBrightness(for: device) }
                             }
                         })
        tvs.append(tv)
        if pair { tv.requestPairing() }
        if start { tv.start() }
    }

    // TVs saved before ids existed get one as they're loaded; write it back straight
    // away, or anything that refers to a TV by id would point at nothing after a restart.
    private func saveAssignedIds() {
        if tvs.contains(where: { $0.device.idWasAssigned }) { persist() }
    }

    /// Re-enumerates connected displays (called when the Home page appears).
    func refreshScreens() {
        screens = ScreenService.list()
    }

    // MARK: - Hotkeys

    /// Nudges brightness by a signed step from a global hotkey, on the TV(s) chosen on
    /// the Hotkeys page (see `RuleTargets.planHotkey` for the rules). A TV whose
    /// automation is paused (linked display not connected) is left alone; if that leaves
    /// nothing to change, the outcome is `.disconnected` so the overlay can say why.
    func nudgeFromHotkey(step: Int) -> HotkeyOutcome {
        let all = tvInfos
        let cursor = { ScreenService.screenIdAtCursor() }
        let paused = Set(tvs.filter(\.automationPaused).map(\.id))
        // A paused TV counts as one that can't be dimmed right now.
        let available = all.map { info in
            paused.contains(info.id)
                ? TvInfo(id: info.id, name: info.name, supportsBrightness: false,
                         pairedScreenId: info.pairedScreenId)
                : info
        }

        let plan = RuleTargets.planHotkey(target: settings.hotkeyTarget, tvs: available, cursorScreen: cursor)
        guard plan.outcome == .adjusted, let shownId = plan.shownTvId, let shown = tv(withId: shownId) else {
            // Would it have worked with every display attached? Then say that's why not.
            if !paused.isEmpty,
               RuleTargets.planHotkey(target: settings.hotkeyTarget, tvs: all, cursorScreen: cursor)
                .outcome == .adjusted {
                return .disconnected
            }
            return plan.outcome == .unpaired ? .unpaired : .none
        }

        for id in plan.tvIds { tv(withId: id)?.nudge(step) }
        return .adjusted(name: plan.tvIds.count == 1 ? shown.name : nil, value: shown.backlight,
                         screenId: shown.linkedScreenId.isEmpty ? nil : shown.linkedScreenId)
    }

    private func handleHotkey(step: Int) {
        let outcome = nudgeFromHotkey(step: step)
        guard settings.osd.enabled else { return }
        switch outcome {
        case .adjusted(let name, let value, let screenId):
            osd.showBrightness(tvName: name, value: value, osd: settings.osd, screenId: screenId)
        case .unpaired:
            osd.showUnpaired(osd: settings.osd)
        case .disconnected:
            osd.showDisconnected(osd: settings.osd)
        case .none:
            break
        }
    }

    /// The Hotkeys page "Which TV" choices: the cursor, all TVs, then each TV that can be
    /// dimmed. A TV picked earlier that can't be dimmed right now stays listed, so the
    /// choice still shows as made.
    var hotkeyTargetChoices: [TvChoice] {
        [TvChoice(id: "", name: "TV under the cursor"), TvChoice(id: RuleTargets.allTvs, name: "All TVs")]
            + tvs.filter { $0.supportsBrightness || $0.id == settings.hotkeyTarget }
                .map { TvChoice(id: $0.id, name: $0.name) }
    }

    /// The "Which TV" chooser only matters with more than one TV.
    var showsHotkeyTarget: Bool { tvs.count > 1 }

    /// The Hotkeys page "Which TV" choice. An id of a TV that's gone reads as the cursor.
    var hotkeyTarget: String {
        get {
            let (mode, tvId) = RuleTargets.resolveHotkeyTarget(settings.hotkeyTarget, tvIds: tvs.map(\.id))
            switch mode {
            case .all: return RuleTargets.allTvs
            case .tv: return tvId ?? ""
            case .cursor: return ""
            }
        }
        set {
            guard newValue != settings.hotkeyTarget else { return }
            settings.hotkeyTarget = newValue
            saveSettings()
        }
    }

    // MARK: - Schedules

    /// Applies one schedule that just fired to the TVs it targets whose brightness is set
    /// up. One that's off or unreachable holds the value and applies it when it's back; one
    /// whose automation is paused remembers that it missed a schedule, so the in-effect
    /// value is applied the moment its display reconnects. Returns the TVs it changed.
    @discardableResult
    func applySchedule(_ schedule: BrightnessSchedule) -> [TvState] {
        var changed: [TvState] = []
        for tv in tvs where tv.acceptsBrightness && RuleTargets.targets(schedule, tvId: tv.id) {
            if tv.automationAllowed {
                tv.applyBrightness(schedule.brightness)
                changed.append(tv)
            } else {
                tv.missedScheduleWhileDisconnected = true
                Log.write("\(tv.host): schedule held, linked display not connected")
            }
        }
        return changed
    }

    /// After the Mac slept through (from, to]: sets each dimmable TV that had a schedule
    /// fire in that gap to the schedule now in effect for it (wrapping to last night's).
    /// TVs whose schedules all stayed quiet are left alone. Returns the TVs it changed.
    @discardableResult
    func catchUpSchedules(from: Date, to: Date) -> [TvState] {
        var changed: [TvState] = []
        for tv in tvs where tv.acceptsBrightness {
            guard let value = RuleTargets.catchUpBrightness(settings.schedules, tvId: tv.id,
                                                            from: from, to: to) else { continue }
            if tv.automationAllowed {
                tv.applyBrightness(value)
                changed.append(tv)
            } else {
                tv.missedScheduleWhileDisconnected = true
                Log.write("\(tv.host): schedule catch-up held, linked display not connected")
            }
        }
        return changed
    }

    // Schedule catch-up when a TV's brightness first becomes usable this session: the
    // schedule in effect for that TV now, or nil when catch-up is off or no schedule
    // targets it. A TV whose automation is paused holds it for display-reconnect instead;
    // its user isn't looking at it right now.
    private func startupBrightness(for device: TvDevice) -> Int? {
        guard settings.applyScheduleOnStartup,
              let value = RuleTargets.scheduledBrightness(settings.schedules, tvId: device.id) else { return nil }
        if let tv = tvs.first(where: { $0.device === device }), !tv.automationAllowed {
            tv.missedScheduleWhileDisconnected = true
            Log.write("\(device.host): startup schedule held, linked display not connected")
            return nil
        }
        return value
    }

    // Shows the OSD after a schedule changed brightness, if the user opted in. One
    // confirmation for the TVs it changed: the value of the first of them in Home page
    // order (falls back to the primary display), named only when a single TV changed.
    private func showScheduleOsd(_ changed: [TvState]) {
        guard settings.osd.enabled, settings.osd.showOnSchedule, let tv = changed.first else { return }
        osd.showBrightness(tvName: changed.count == 1 ? tv.name : nil, value: tv.backlight, osd: settings.osd,
                           screenId: tv.linkedScreenId, allowFallback: true)
    }

    /// Shows the OSD on demand (Preview button), ignoring the enable switch.
    func previewOsd() {
        let tv = tvs.first
        osd.showBrightness(tvName: tv?.name ?? "TV", value: tv?.backlight ?? 50, osd: settings.osd,
                           screenId: tv?.linkedScreenId, allowFallback: true)
    }

    var canAddSchedule: Bool { settings.schedules.count < 10 }

    func addSchedule() {
        guard canAddSchedule else { return }
        settings.schedules.append(BrightnessSchedule())
        persistSchedules()
    }

    func removeSchedule(_ schedule: BrightnessSchedule) {
        settings.schedules.removeAll { $0.id == schedule.id }
        persistSchedules()
    }

    func persistSchedules() {
        settings.schedules.sort { $0.minutesOfDay < $1.minutesOfDay }
        saveSettings()
    }

    /// A schedule's TV picker only appears with at least two TVs that can be dimmed. The
    /// one exception: a schedule that names TVs none of which can be dimmed right now (say
    /// a Google TV that lost brightness control) keeps it, or it would silently do nothing
    /// with no way to see why.
    func showsTargetPicker(for schedule: BrightnessSchedule) -> Bool {
        let dimmable = tvs.filter(\.supportsBrightness).map(\.id)
        let stranded = !schedule.tvIds.isEmpty && !schedule.tvIds.contains(where: dimmable.contains)
        return dimmable.count >= 2 || stranded
    }

    // MARK: - Settings proxies (each setter persists immediately)

    var startAtLogin: Bool {
        get { settings.startAtLogin }
        set {
            guard newValue != settings.startAtLogin else { return }
            settings.startAtLogin = newValue
            AutostartService.apply(newValue)
            saveSettings()
        }
    }

    var launchBehavior: Int {
        get { settings.launchBehavior }
        set { settings.launchBehavior = newValue; saveSettings() }
    }

    var showMenuBarIcon: Bool {
        get { settings.showMenuBarIcon }
        set {
            guard newValue != settings.showMenuBarIcon else { return }
            settings.showMenuBarIcon = newValue
            saveSettings()
        }
    }

    var hotkeyStep: Int {
        get { settings.hotkeyStep }
        set {
            let step = max(1, min(25, newValue))
            guard step != settings.hotkeyStep else { return }
            settings.hotkeyStep = step
            saveSettings()
        }
    }

    var themeIndex: Int {
        get { settings.themeIndex }
        set {
            guard newValue != settings.themeIndex else { return }
            settings.themeIndex = newValue
            saveSettings()
            applyTheme()
        }
    }

    var applyScheduleOnStartup: Bool {
        get { settings.applyScheduleOnStartup }
        set { settings.applyScheduleOnStartup = newValue; saveSettings() }
    }

    func applyTheme() {
        NSApp.appearance = switch settings.themeIndex {
        case 1: NSAppearance(named: .aqua)
        case 2: NSAppearance(named: .darkAqua)
        default: nil // follow the system
        }
    }

    // Hotkey modifiers (Control/Option/Shift/Command), combined with the Up/Down arrows.
    // At least one is always kept: a bare arrow hotkey would swallow every arrow press
    // system-wide. Bit values match TVControlForWin: 1=Option(Alt), 2=Control(Ctrl),
    // 4=Shift, 8=Command(Win).
    var hotkeyControl: Bool { get { hasMod(2) } set { setMod(2, newValue) } }
    var hotkeyOption: Bool { get { hasMod(1) } set { setMod(1, newValue) } }
    var hotkeyShift: Bool { get { hasMod(4) } set { setMod(4, newValue) } }
    var hotkeyCommand: Bool { get { hasMod(8) } set { setMod(8, newValue) } }

    /// Human-readable combo for display, e.g. "⌃ ⌥ + ↑ / ↓".
    var hotkeyComboText: String {
        var parts: [String] = []
        if hotkeyControl { parts.append("⌃") }
        if hotkeyOption { parts.append("⌥") }
        if hotkeyShift { parts.append("⇧") }
        if hotkeyCommand { parts.append("⌘") }
        return parts.isEmpty ? "↑ / ↓" : parts.joined(separator: " ") + " + ↑ / ↓"
    }

    private func hasMod(_ bit: Int) -> Bool { settings.hotkeyModifiers & bit != 0 }

    private func setMod(_ bit: Int, _ on: Bool) {
        let current = settings.hotkeyModifiers
        var next = on ? current | bit : current & ~bit
        if next == 0 { next = current } // don't allow clearing the last modifier
        guard next != current else { return }
        settings.hotkeyModifiers = next
        saveSettings()
        hotkeys.update(modifiers: next)
    }

    // MARK: - Backup / restore

    /// Returns the full configuration (TVs + settings) as a single JSON string.
    func exportSettings() -> String {
        store.serializeBackup(devices: tvs.map(\.device), settings: settings)
    }

    /// Replaces all TVs and settings from a backup string and reloads live state.
    /// Accepts TVControlForWin backups too; the format is the same.
    func importSettings(_ json: String) throws {
        let data = try store.deserializeBackup(json) // throws before we touch anything
        store.saveDevices(data.devices!)
        store.saveSettings(data.settings!)
        reloadFromStore()
    }

    private func reloadFromStore() {
        for tv in tvs { tv.dispose() }
        tvs.removeAll()
        for device in store.loadDevices() {
            add(device, start: true)
        }
        saveAssignedIds()
        refreshScreens()

        settings = store.loadSettings()
        AutostartService.apply(settings.startAtLogin)
        applyTheme()
        hotkeys.update(modifiers: settings.hotkeyModifiers)
        updateDisplayPresence()
    }

    func persist() {
        store.saveDevices(tvs.map(\.device))
    }

    func saveSettings() {
        store.saveSettings(settings)
    }

    /// Releases hotkeys, sockets and persists state before exit.
    func shutdown() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        powerEvents.dispose()
        hotkeys.dispose()
        scheduleService.dispose()
        osd.close()
        persist()
        for tv in tvs { tv.dispose() }
    }
}
