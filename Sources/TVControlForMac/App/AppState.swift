import AppKit
import Network
import Observation

/// Outcome of a cursor-targeted brightness hotkey: a TV was adjusted, no paired TV was
/// under the cursor (prompt to pair), the only TV's linked display is unplugged and its
/// automation gate is on, or there are no TVs at all.
enum HotkeyOutcome {
    case adjusted(name: String, value: Int, screenId: String?)
    case unpaired
    case disconnected
    case none
}

/// Top-level app state: TVs, schedules, settings and hotkey routing — shared by the
/// main window, the menu bar extra and the background services (TVControlForWin's MainViewModel).
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    private let store = DeviceStore()

    var settings: AppSettings
    var tvs: [TvState] = []
    /// Connected displays, for pairing each TV to the screen it drives. Refreshed on demand.
    var screens: [ScreenInfo] = []

    /// True after repeated unreachable-TV connect cycles — the usual cause on macOS is the
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
                // Once per launch, nudge macOS to show the Local Network prompt itself —
                // a multicast is what reliably makes the system (re)register the app.
                if !promptRetriggered {
                    promptRetriggered = true
                    requestLocalNetworkAccess()
                }
            }
        }
    }

    /// Opens System Settings at Privacy & Security — the app needs its Network (macOS 26+)
    /// and/or Local Network toggles enabled there.
    func openLocalNetworkSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        NSWorkspace.shared.open(pane)
    }

    @ObservationIgnored private var permissionProbes: [Any] = []

    /// Nudges macOS to (re)show the Local Network permission prompt. Uses several paths
    /// because registration is flaky on recent macOS: an SSDP multicast burst, a Bonjour
    /// browse, and a direct Network.framework connection to the first TV — NWBrowser /
    /// NWConnection go through the local-network privacy machinery explicitly.
    func requestLocalNetworkAccess() {
        Task { _ = await SsdpDiscovery.findTvs(timeout: 2) }

        let browser = NWBrowser(for: .bonjour(type: "_airplay._tcp", domain: nil), using: .init())
        browser.start(queue: .global())
        permissionProbes.append(browser)

        if let host = tvs.first?.host {
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 3000, using: .tcp)
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

    let appVersion = "v" + AppInfo.version

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
        tvs.first?.isActive = true
        refreshScreens()
    }

    /// Wires services and kicks off connections. Called once at launch.
    func start() {
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
        scheduleService.getCurrentScheduledBrightness = { [weak self] in self?.currentScheduledBrightness() }
        scheduleService.applyBrightnessAll = { [weak self] value in self?.applyBrightnessAll(value) }
        scheduleService.onScheduleApplied = { [weak self] value in self?.showScheduleOsd(value) }
        scheduleService.start()

        // Order matters: the on-app-start wake decision must read the persisted display
        // presence from the previous session, BEFORE live tracking overwrites it (a TV
        // that's off has no HDMI link, so a live sample would always say "absent").
        wirePowerAutomation()
        startDisplayTracking()

        // Hidden test/debug hook: `--osd-preview` posts this distributed notification so
        // the OSD can be exercised without clicking through the UI.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.itsallexb.TVControlForMac.osd-preview"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppState.shared.previewOsd() }
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
                if let value = currentScheduledBrightness() {
                    Log.write("\(tv.host): display is back — applying scheduled \(value)%")
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

    private func wirePowerAutomation() {
        // Sleep and shutdown give handlers only moments — send the off commands over the
        // already-open sockets and wait briefly, then let go.
        powerEvents.onSuspending = { [weak self] in
            guard let self else { return }
            self.systemAwake = false // presence is frozen until the Mac is back
            guard self.settings.power.offOnSleep else { return }
            self.turnOffAllBlocking(timeout: 1.5)
        }
        powerEvents.onSessionEnding = { [weak self] in
            guard let self else { return }
            self.systemAwake = false
            guard self.settings.power.offOnShutdown else { return }
            self.turnOffAllBlocking(timeout: 2.0)
        }
        powerEvents.onResumed = { [weak self] in
            guard let self else { return }
            self.systemAwake = true
            if self.settings.power.onResume {
                self.powerOnAll() // decided from presence as of falling asleep
            }
            self.updateDisplayPresence()
        }
        powerEvents.onDisplayStateChanged = { [weak self] on in
            guard let self else { return }
            let power = self.settings.power
            if !on {
                self.displaysOn = false // freeze presence before the TVs power down
                if power.followDisplayOff {
                    if power.displayOffAction == 1 {
                        self.turnOffAll()
                    } else {
                        self.screenOffAll()
                    }
                }
            } else {
                self.displaysOn = true
                if power.followDisplayOn {
                    self.powerOnAll() // before re-sampling — a woken TV isn't back on HDMI yet
                }
                self.refreshScreens()
                self.updateDisplayPresence()
            }
        }

        // "Turn on when the Mac starts": the app just started, so wake the TVs now. WoL
        // reaches TVs that are off; ones already on simply ignore it.
        if settings.power.onAppStart {
            powerOnAll()
        }
    }

    /// The TVs automation may touch right now — skips any TV whose linked display is
    /// required but not connected. Manual controls always target a TV directly instead.
    private var automationTargets: [TvState] {
        tvs.filter { tv in
            if tv.automationAllowed { return true }
            Log.write("\(tv.host): automation skipped — linked display not connected")
            return false
        }
    }

    func turnOffAll() {
        for tv in automationTargets { Task { await tv.turnOff() } }
    }

    func screenOffAll() {
        for tv in automationTargets { Task { await tv.screenOff() } }
    }

    func powerOnAll() {
        for tv in automationTargets { Task { await tv.powerOn() } }
    }

    // Blocks the calling (main) thread briefly so the off commands make it onto the wire
    // before the system finishes sleeping / logging out — same trick as TVControlForWin's
    // TurnOffAllAsync().Wait(…). The sends themselves run off the main thread.
    private func turnOffAllBlocking(timeout: TimeInterval) {
        let controllers = automationTargets.map(\.controller)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for controller in controllers {
                    group.addTask { await controller.turnOff() }
                }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    // MARK: - TVs

    var activeTv: TvState? { tvs.first(where: \.isActive) ?? tvs.first }

    func setActive(_ tv: TvState) {
        for t in tvs { t.isActive = t === tv }
    }

    /// True when a TV with this host/IP is already in the list (used by discovery).
    func hasTv(host: String) -> Bool {
        tvs.contains { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    func addTv(name: String, host: String) {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        add(TvDevice(name: trimmedName.isEmpty ? "LG TV" : trimmedName, host: trimmedHost), start: true)
        persist()
    }

    /// Adds a TV found by network discovery (no-op if its IP is already added).
    func addDiscoveredTv(_ tv: DiscoveredTv) {
        guard !hasTv(host: tv.host) else { return }
        add(TvDevice(name: tv.name, host: tv.host), start: true)
        persist()
    }

    func removeTv(_ tv: TvState) {
        guard let index = tvs.firstIndex(where: { $0 === tv }) else { return }
        tvs.remove(at: index)
        tv.dispose()
        if tv.isActive { tvs.first?.isActive = true }
        persist()
    }

    func moveTvs(from source: IndexSet, to destination: Int) {
        tvs.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func add(_ device: TvDevice, start: Bool) {
        let tv = TvState(device: device, persist: { [weak self] in self?.persist() },
                         startupBrightness: { [weak self] in
                             DispatchQueue.main.sync {
                                 MainActor.assumeIsolated { self?.startupBrightness(for: device) }
                             }
                         })
        tvs.append(tv)
        if tvs.count == 1 { tv.isActive = true }
        if start { tv.start() }
    }

    /// Re-enumerates connected displays (called when the Home page appears).
    func refreshScreens() {
        screens = ScreenService.list()
    }

    // MARK: - Hotkeys

    /// Nudges brightness by a signed step from a global hotkey, targeting the TV on the
    /// screen the cursor is currently on. With a single TV it always targets that one (no
    /// pairing needed). With several TVs and the cursor on a screen no TV is paired to, it
    /// changes nothing and reports `.unpaired` so the OSD can prompt the user to pair.
    func nudgeByCursor(step: Int) -> HotkeyOutcome {
        guard !tvs.isEmpty else { return .none }

        let tv: TvState
        if tvs.count == 1 {
            tv = tvs[0] // only one TV → unambiguous, ignore the cursor
            // …unless its automation gate says its display must be attached. (With
            // several TVs the cursor must be ON the linked display, so no check needed.)
            guard tv.automationAllowed else { return .disconnected }
        } else {
            guard let cursorScreen = ScreenService.screenIdAtCursor(),
                  let match = tvs.first(where: { $0.device.pairedScreenId == cursorScreen }) else {
                return .unpaired
            }
            tv = match
        }

        tv.nudge(step)
        return .adjusted(name: tv.name, value: tv.backlight,
                         screenId: tv.device.pairedScreenId.isEmpty ? nil : tv.device.pairedScreenId)
    }

    private func handleHotkey(step: Int) {
        switch nudgeByCursor(step: step) {
        case .adjusted(let name, let value, let screenId):
            guard settings.osd.enabled else { return }
            osd.showBrightness(tvName: name, value: value, osd: settings.osd, screenId: screenId)
        case .unpaired:
            guard settings.osd.enabled else { return }
            osd.showUnpaired(osd: settings.osd)
        case .disconnected:
            guard settings.osd.enabled else { return }
            osd.showDisconnected(osd: settings.osd)
        case .none:
            break
        }
    }

    // MARK: - Schedules

    /// Sets every TV to the given brightness (used by schedules). A TV whose automation
    /// is paused is skipped but remembers that it missed a schedule, so the in-effect
    /// value is applied the moment its display reconnects.
    func applyBrightnessAll(_ value: Int) {
        for tv in tvs {
            if tv.automationAllowed {
                tv.applyBrightness(value)
            } else {
                tv.missedScheduleWhileDisconnected = true
                Log.write("\(tv.host): schedule held — linked display not connected")
            }
        }
    }

    /// The brightness that should currently be in effect per the schedules: the most recent
    /// enabled schedule that has already passed today, wrapping to the latest one overall
    /// (i.e. last night's) if none have passed yet today. Nil if none are enabled.
    func currentScheduledBrightness() -> Int? {
        let enabled = settings.schedules.filter(\.enabled)
        guard !enabled.isEmpty else { return nil }

        let now = Date()
        let calendar = Calendar.current
        let nowMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)

        let inEffect = enabled
            .filter { $0.minutesOfDay <= nowMinutes }
            .max(by: { $0.minutesOfDay < $1.minutesOfDay })
            ?? enabled.max(by: { $0.minutesOfDay < $1.minutesOfDay })! // wrap to last night's

        return inEffect.brightness
    }

    // Catch-up value applied to a TV on its first connect (nil when disabled or no
    // schedules). A TV whose automation is paused holds the value for display-reconnect
    // instead — its user isn't looking at it right now.
    private func startupBrightness(for device: TvDevice) -> Int? {
        guard settings.applyScheduleOnStartup, let value = currentScheduledBrightness() else { return nil }
        if let tv = tvs.first(where: { $0.device === device }), !tv.automationAllowed {
            tv.missedScheduleWhileDisconnected = true
            Log.write("\(device.host): startup schedule held — linked display not connected")
            return nil
        }
        return value
    }

    // Shows the OSD after a schedule applied brightness, if the user opted in. Schedules
    // affect all TVs, so it's one confirmation (falls back to the primary display), named
    // only when there's a single TV. Nothing to confirm when every TV was skipped.
    private func showScheduleOsd(_ value: Int) {
        guard settings.osd.enabled, settings.osd.showOnSchedule else { return }
        guard tvs.contains(where: \.automationAllowed) else { return }
        let tv = activeTv
        osd.showBrightness(tvName: tvs.count == 1 ? tv?.name : nil, value: value, osd: settings.osd,
                           screenId: tv?.device.pairedScreenId, allowFallback: true)
    }

    /// Shows the OSD on demand (Preview button), ignoring the enable toggle.
    func previewOsd() {
        let tv = activeTv
        osd.showBrightness(tvName: tv?.name ?? "LG TV", value: tv?.backlight ?? 50, osd: settings.osd,
                           screenId: tv?.device.pairedScreenId, allowFallback: true)
    }

    func addSchedule() {
        guard settings.schedules.count < 10 else { return }
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

    // MARK: - Settings proxies (each setter persists immediately, like TVControlForWin)

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
    // At least one is always kept — a bare arrow hotkey would swallow every arrow press
    // system-wide. Bit values match TVControlForWin: 1=Option(Alt), 2=Control(Ctrl), 4=Shift, 8=Command(Win).
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
    /// Accepts TVControlForWin backups too — the format is identical.
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
        tvs.first?.isActive = true
        refreshScreens()

        settings = store.loadSettings()
        AutostartService.apply(settings.startAtLogin)
        applyTheme()
        hotkeys.update(modifiers: settings.hotkeyModifiers)
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
