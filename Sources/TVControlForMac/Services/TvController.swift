// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

enum TvStatus {
    case disconnected
    case connecting
    /// webOS: the TV is showing an accept prompt; nothing to do in the app.
    case awaitingPairing
    case connected
    case error
    /// Not paired, and pairing only starts when the user asks for it
    /// (`TvController.requestPairing`), because it puts a dialog on the TV.
    case needsPairing
    /// The TV is showing a code that has to be typed into the app
    /// (`TvController.submitPairingCode`).
    case awaitingCode
}

/// Where a TV stands on brightness control. LG TVs are simply `.ready`; a Google TV gets
/// there through a one-time setup, because its brightness is reached over ADB, which the
/// owner has to switch on and approve on the TV.
enum BrightnessSetup {
    /// Not known yet: the TV hasn't connected since the app started.
    case unknown
    /// No way to control this TV's brightness: it's a power-only TV.
    case unavailable
    /// Could work on this TV; the user hasn't set it up (or it stopped being approved).
    case offered
    /// Setup is running.
    case connecting
    /// Setup couldn't reach ADB: USB debugging isn't switched on on the TV.
    case needsDebugging
    /// The TV is showing "Allow USB debugging?" and waiting for an answer.
    case awaitingApproval
    /// Brightness can be read and set.
    case ready
    /// ADB works, but this model doesn't expose a brightness control we know.
    case unsupported
}

/// One TV, whatever protocol it speaks: owns the connection, keeps it alive, and exposes
/// the operations the rest of the app is built on. Brands differ in what they can do, so
/// callers check the `supports…` flags rather than the concrete type.
///
/// Every callback may fire on a background thread; the owner hops to the main actor.
protocol TvController: AnyObject {
    var device: TvDevice { get }
    var status: TvStatus { get }

    /// Whether this TV's brightness can be read and set over the network right now.
    /// Can change while the app runs; see `onCapabilitiesChanged`.
    var supportsBrightness: Bool { get }

    /// Whether a value given to `setBacklight` gets to the TV, now or once it's back.
    /// Wider than `supportsBrightness`: a TV that's set up but off or unreachable still
    /// takes a schedule's value and applies it later.
    var acceptsBrightness: Bool { get }

    /// How far along brightness control is for this TV.
    var brightnessSetup: BrightnessSetup { get }

    /// True when the TV can be woken over the network (MAC already learned).
    var canWake: Bool { get }

    /// Optional: returns the brightness to apply once, on the first successful connect
    /// this session (schedule catch-up). Return nil to skip.
    var getStartupBrightness: (() -> Int?)? { get set }

    /// Fires (status, optional message) whenever the connection state changes.
    var onStatusChanged: ((TvStatus, String?) -> Void)? { get set }
    /// Fires when something persisted on `device` changed (pairing credentials, the
    /// learned MAC address), so the owner can save it.
    var onDeviceChanged: (() -> Void)? { get set }
    /// Fires when the TV's current brightness is read, so the UI can sync the slider.
    var onBacklightReported: ((Int) -> Void)? { get set }
    /// Fires when the TV reports a new power state ("Active", "Screen Off", "Standby", …),
    /// so the UI can tell a live connection from a TV that's actually switched on.
    var onPowerStateReported: ((String) -> Void)? { get set }
    /// Fires when `supportsBrightness` or `brightnessSetup` changes.
    var onCapabilitiesChanged: (() -> Void)? { get set }

    /// Connects and keeps the connection alive, retrying with backoff until disposed.
    func start()

    /// Queues a brightness change. No-op when `acceptsBrightness` is false.
    func setBacklight(_ value: Int)

    /// Turns the TV off. Returns false if it isn't connected or the TV refused.
    @discardableResult func turnOff() async -> Bool
    /// Blanks the panel while the TV keeps running. TVs that can't do that turn off instead.
    @discardableResult func screenOff() async -> Bool
    /// Powers the TV on (or un-blanks it), retrying until it answers.
    func powerOn() async
    /// Turns the TV off if it's awake, wakes it if it isn't.
    func togglePower() async

    /// Starts (or retries) brightness setup for a TV that offers it. It may put an approval
    /// dialog on the TV, so it only ever runs because the user asked. No-op otherwise.
    func setUpBrightness()
    /// Starts pairing for a TV in `.needsPairing`. No-op otherwise.
    func requestPairing()
    /// Submits the code the TV is showing while in `.awaitingCode`.
    func submitPairingCode(_ code: String)

    func dispose()
}
