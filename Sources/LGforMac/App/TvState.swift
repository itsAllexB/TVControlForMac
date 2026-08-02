import AppKit
import Observation

/// UI-facing wrapper around one TvDevice and its TvController (LGforWin's TvViewModel).
@MainActor
@Observable
final class TvState: Identifiable {
    let device: TvDevice
    let controller: TvController
    private let persist: () -> Void
    private var suppressSend = false

    nonisolated let id = UUID()

    var backlight: Int {
        didSet {
            guard !suppressSend, backlight != oldValue else { return }
            controller.setBacklight(backlight)
            persist()
        }
    }

    var statusText = "Disconnected"
    var isConnected = false
    var isBusy = false
    /// True when this is the TV selected on the Home page (the "Active" pill).
    var isActive = false

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
    /// A schedule fired while automation was paused — applied when the display returns.
    var missedScheduleWhileDisconnected = false

    /// The per-TV "Automate only while connected" toggle.
    var automationGate: Bool {
        didSet {
            guard automationGate != oldValue else { return }
            device.automationOnlyWhenConnected = automationGate
            persist()
            AppState.shared.updateDisplayPresence()
        }
    }

    /// False when automation (schedules, power rules, single-TV hotkeys) must skip this
    /// TV because its linked display isn't connected. Manual controls ignore this.
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

    var name: String { device.name }
    var host: String { device.host }

    init(device: TvDevice, persist: @escaping () -> Void, startupBrightness: (() -> Int?)?) {
        self.device = device
        self.persist = persist
        self.backlight = device.lastBacklight
        self.linkedScreenId = device.pairedScreenId
        self.linkedScreenName = device.pairedScreenName
        self.automationGate = device.automationOnlyWhenConnected
        // Seed presence from the persisted snapshot; live tracking corrects it once the
        // displays are up. Unlinked TVs never gate, so they read as "connected".
        self.displayConnected = device.pairedScreenId.isEmpty || device.lastDisplayConnected

        controller = TvController(device: device)
        controller.getStartupBrightness = startupBrightness

        controller.onStatusChanged = { [weak self] status, message in
            Task { @MainActor in self?.handleStatus(status, message) }
        }
        controller.onClientKeyUpdated = { [weak self] _ in
            Task { @MainActor in self?.persist() }
        }
        controller.onBacklightReported = { [weak self] value in
            Task { @MainActor in self?.setBacklightQuietly(value) }
        }
        controller.onMacAddressResolved = { [weak self] _ in
            Task { @MainActor in self?.persist() } // keep the learned MAC for WoL
        }
        controller.onPowerStateReported = { [weak self] state in
            Task { @MainActor in self?.handlePowerState(state) }
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

    // MARK: - Power

    func turnOff() async { await controller.turnOff() }
    func screenOff() async { await controller.screenOff() }
    func powerOn() async { await controller.powerOn() }

    /// The power button: turns the TV off when it's awake, wakes it when it isn't.
    func togglePower() async {
        if !isConnected && !controller.canWake {
            statusText = "Can't wake yet — connect once so the MAC address is learned"
            return
        }
        await controller.togglePower()
    }

    // MARK: - Controller events

    private func handleStatus(_ status: TvStatus, _ message: String?) {
        isConnected = status == .connected
        isBusy = status == .connecting || status == .awaitingPairing
        if status == .connected {
            AppState.shared.noteConnectOutcome(success: true)
        } else if status == .error {
            AppState.shared.noteConnectOutcome(success: false)
        }
        statusText = message ?? {
            switch status {
            case .connected: return "Connected"
            case .connecting: return "Connecting…"
            case .awaitingPairing: return "Accept the prompt on your TV"
            case .error: return "Error"
            case .disconnected: return "Disconnected"
            }
        }()
    }

    // The socket can be perfectly healthy while the TV itself is in standby, so say which
    // it is rather than a bare "Connected".
    private func handlePowerState(_ state: String) {
        guard isConnected else { return } // a status change is already describing the connection
        let lower = state.lowercased()
        if lower.contains("screen off") {
            statusText = "Connected · screen off"
        } else if lower.contains("standby") || lower.contains("suspend") || lower.contains("power off") {
            statusText = "Connected · TV is off"
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
