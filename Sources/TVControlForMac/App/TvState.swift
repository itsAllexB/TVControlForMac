// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Observation

/// UI-facing wrapper around one TvDevice and its TvController (TVControlForWin's TvViewModel).
@MainActor
@Observable
final class TvState: Identifiable {
    let device: TvDevice
    @ObservationIgnored let controller: TvController
    private let persist: () -> Void
    private var suppressSend = false

    /// Stable id that rules (schedules, power, hotkeys) use to name this TV.
    nonisolated let id: String

    var backlight: Int {
        didSet {
            guard !suppressSend, backlight != oldValue else { return }
            controller.setBacklight(backlight)
            persist()
        }
    }

    private(set) var status: TvStatus = .disconnected
    var statusText = "Not connected"
    var isConnected = false
    var isBusy = false

    // MARK: - What this TV can do
    // Observable mirrors of the controller's flags (the controller isn't observable, and
    // reports changes from background threads). Refreshed by `refreshCapabilities`.

    /// False for TVs whose brightness can't be set (yet); they get power control only.
    /// Can change while the app runs: a Google TV gains it once ADB brightness is set up.
    private(set) var supportsBrightness: Bool
    private(set) var brightnessSetup: BrightnessSetup

    /// True when setting `backlight` reaches the TV now or once it's back. What schedules
    /// go by, so one that fires while a TV is unreachable isn't lost. Read live.
    var acceptsBrightness: Bool { controller.acceptsBrightness }

    /// What rule targeting needs to know about this TV, as of now.
    var info: TvInfo {
        TvInfo(id: id, name: name, supportsBrightness: supportsBrightness, pairedScreenId: linkedScreenId)
    }

    /// Short protocol name shown next to the address, e.g. "LG webOS".
    var kindLabel: String { device.kind.label }

    // MARK: - Linked display
    // Observable mirrors of the device's link fields (TvDevice itself isn't observable).
    // The device stays the source of truth for persistence and hotkey matching.

    /// Stable id of the linked display ("" = not linked).
    private(set) var linkedScreenId: String
    /// Friendly name of the linked display, kept so it can be named while unplugged.
    private(set) var linkedScreenName: String
    /// Whether the linked display is present. Maintained by AppState only while the Mac
    /// is awake with displays on (see TvDevice.lastDisplayConnected); true when unlinked.
    var displayConnected: Bool
    /// A schedule fired while automation was paused; applied when the display returns.
    var missedScheduleWhileDisconnected = false

    /// The per-TV "Only while connected" switch.
    var automationGate: Bool {
        didSet {
            guard automationGate != oldValue else { return }
            device.automationOnlyWhenConnected = automationGate
            persist()
            AppState.shared.updateDisplayPresence()
        }
    }

    /// False when automation (schedules, power rules, hotkeys) must skip this TV because
    /// its linked display isn't connected. The controls on its card ignore this.
    var automationAllowed: Bool {
        !automationGate || linkedScreenId.isEmpty || displayConnected
    }

    var automationPaused: Bool { !automationAllowed }

    /// Points the link at a (new) display, or unlinks with empty values.
    func setLink(screenId: String, name: String) {
        linkedScreenId = screenId
        linkedScreenName = name
        device.pairedScreenId = screenId
        device.pairedScreenName = name
        missedScheduleWhileDisconnected = false
    }

    /// Keeps the stored display name current (displays can be renamed in System Settings).
    func refreshLinkName(_ name: String) {
        linkedScreenName = name
        device.pairedScreenName = name
    }

    // MARK: - Power rules

    /// This TV's own power rules, or nil while it follows the shared ones.
    var ownPower: PowerSettings? {
        didSet {
            guard ownPower != oldValue else { return }
            device.power = ownPower
            persist()
        }
    }

    var name: String { device.name }
    var host: String { device.host }

    /// - Parameter startupBrightness: schedule catch-up; asked once, when this TV's
    ///   brightness first becomes usable, for the value it should start at (nil to leave
    ///   it). Called off the main thread.
    init(device: TvDevice, persist: @escaping () -> Void, startupBrightness: (() -> Int?)?) {
        self.device = device
        self.id = device.id
        self.persist = persist
        self.backlight = device.lastBacklight
        self.linkedScreenId = device.pairedScreenId
        self.linkedScreenName = device.pairedScreenName
        self.automationGate = device.automationOnlyWhenConnected
        self.ownPower = device.power
        // Seed presence from the persisted snapshot; live tracking corrects it once the
        // displays are up. Unlinked TVs never gate, so they read as "connected".
        self.displayConnected = device.pairedScreenId.isEmpty || device.lastDisplayConnected

        let controller = TvControllerFactory.create(device)
        self.controller = controller
        self.supportsBrightness = controller.supportsBrightness
        self.brightnessSetup = controller.brightnessSetup
        controller.getStartupBrightness = startupBrightness

        controller.onStatusChanged = { [weak self] status, message in
            Task { @MainActor in self?.handleStatus(status, message) }
        }
        // Pairing credentials, the learned MAC for Wake-on-LAN. Raised on background
        // threads, and saving walks the TV list, so it's handed to the main actor.
        controller.onDeviceChanged = { [weak self] in
            Task { @MainActor in self?.persist() }
        }
        controller.onBacklightReported = { [weak self] value in
            Task { @MainActor in self?.setBacklightQuietly(value) }
        }
        controller.onPowerStateReported = { [weak self] state in
            Task { @MainActor in self?.handlePowerState(state) }
        }
        controller.onCapabilitiesChanged = { [weak self] in
            Task { @MainActor in self?.refreshCapabilities() }
        }
    }

    func start() {
        controller.start()
    }

    /// Nudge brightness by a signed step (used by global hotkeys).
    func nudge(_ step: Int) {
        backlight = max(0, min(100, backlight + step))
    }

    /// Sets the slider and pushes to the TV (used by schedules).
    func applyBrightness(_ value: Int) {
        backlight = max(0, min(100, value))
    }

    private func refreshCapabilities() {
        supportsBrightness = controller.supportsBrightness
        brightnessSetup = controller.brightnessSetup
    }

    // MARK: - Pairing by code (TVs that show a code to type in, rather than an accept prompt)

    /// What the user has typed of the code on the TV.
    var pairingCode = ""

    /// The pairing strip shows while the TV isn't paired or is waiting for its code.
    var showsPairing: Bool { status == .needsPairing || status == .awaitingCode }

    /// The brightness slider shows once it can act: not while the TV still has to be paired
    /// (an LG showing its accept prompt, a Google TV that needs pairing again), when the
    /// value would only be a default the TV never reported, and nothing would reach it.
    var showsSlider: Bool { supportsBrightness && !showsPairing && status != .awaitingPairing }
    var awaitingCode: Bool { status == .awaitingCode }

    /// Asks the TV to show its pairing code. Called for a just-added TV and by the Pair button.
    func requestPairing() {
        controller.requestPairing()
    }

    /// The pairing strip's button: starts pairing, or submits the typed code.
    func advancePairing() {
        if status == .awaitingCode {
            let code = pairingCode.trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else { return }
            controller.submitPairingCode(code)
            pairingCode = ""
        } else {
            controller.requestPairing()
        }
    }

    // MARK: - Brightness setup (Google TVs, where it goes over ADB and needs switching on once)

    /// The setup strip shows while brightness could work but doesn't yet.
    var showsBrightnessSetup: Bool {
        switch brightnessSetup {
        case .offered, .connecting, .needsDebugging, .awaitingApproval, .unsupported: true
        case .unknown, .unavailable, .ready: false
        }
    }

    var brightnessSetupText: String {
        switch brightnessSetup {
        case .connecting: "Connecting…"
        case .needsDebugging: "Turn on USB debugging, then try again"
        case .awaitingApproval: "Select Allow on the TV"
        case .unsupported: "Not available on this TV"
        default: "Needs USB debugging on the TV"
        }
    }

    /// The steps on the TV, for the strip's info button.
    static let brightnessSetupHelp = """
        1. On the TV, open Settings > System > About.
        2. Select “Android TV OS build” 7 times.
        3. Open Settings > System > Developer options and turn on USB debugging.
        4. Select Set Up here. When the TV asks, tick “Always allow” and select Allow.
        """

    var brightnessSetupButtonText: String? {
        switch brightnessSetup {
        case .offered: "Set Up"
        case .needsDebugging: "Try Again"
        default: nil
        }
    }

    var brightnessSetupBusy: Bool {
        brightnessSetup == .connecting || brightnessSetup == .awaitingApproval
    }

    /// The setup strip's button. The TV may ask for approval as a result.
    func setUpBrightness() {
        controller.setUpBrightness()
    }

    /// True for a TV whose brightness can't be controlled, so the missing slider can be
    /// explained rather than look like a fault.
    var isPowerOnly: Bool { brightnessSetup == .unavailable }

    /// Shown on hovering the card's detail line: what to check while the TV can't be
    /// reached, or why a power-only TV has no brightness. Nil the rest of the time.
    var statusHelp: String? {
        if status == .error || status == .disconnected {
            let base = "Check that the TV is on, on the same network as this Mac, and that the IP address is right."
            return device.kind == .webOs
                ? base + " On older LG TVs, also turn on LG Connect Apps in the TV's network settings."
                : base
        }
        return isPowerOnly
            ? "Brightness isn't supported on this TV's brand yet. Turning it on and off works."
            : nil
    }

    // MARK: - Power

    func turnOff() async { await controller.turnOff() }
    func screenOff() async { await controller.screenOff() }
    func powerOn() async { await controller.powerOn() }

    /// The power button: turns the TV off when it's awake, wakes it when it isn't.
    func togglePower() async {
        if !isConnected && !controller.canWake {
            statusText = "Can't turn on until it has connected once"
            return
        }
        await controller.togglePower()
    }

    // MARK: - Controller events

    private func handleStatus(_ status: TvStatus, _ message: String?) {
        self.status = status
        isConnected = status == .connected
        isBusy = status == .connecting || status == .awaitingPairing
        // Controllers report progress in the words TVControlForWin uses; the Mac writes
        // something still going on with an ellipsis.
        let inProgress = ["Connecting", "Reconnecting"]
        statusText = message.map { inProgress.contains($0) ? $0 + "…" : $0 } ?? {
            switch status {
            case .connected: "Connected"
            case .connecting: "Connecting…"
            case .awaitingPairing: "Accept the prompt on the TV"
            case .needsPairing: "Not paired"
            case .awaitingCode: "Enter the code from the TV"
            case .error: "Can't connect"
            case .disconnected: "Not connected"
            }
        }()

        // Feeds the "is macOS blocking the local network?" detector: a TV that connects
        // clears it; one that can't be reached at all counts towards it.
        if status == .connected {
            AppState.shared.noteConnectOutcome(success: true)
        } else if status == .error || message == "Can't reach the TV" {
            AppState.shared.noteConnectOutcome(success: false)
        }
    }

    // The connection can be perfectly healthy while the TV itself is in standby, so say
    // which it is rather than a bare "Connected".
    private func handlePowerState(_ state: String) {
        guard isConnected else { return } // a status change is already describing the connection
        let lower = state.lowercased()
        if lower.contains("screen off") {
            statusText = "Screen off"
        } else if lower.contains("standby") || lower.contains("suspend") || lower.contains("power off") {
            statusText = "TV is off"
        } else {
            statusText = "Connected"
        }
    }

    private func setBacklightQuietly(_ value: Int) {
        suppressSend = true
        backlight = value
        suppressSend = false
    }

    func dispose() {
        controller.dispose()
    }
}
