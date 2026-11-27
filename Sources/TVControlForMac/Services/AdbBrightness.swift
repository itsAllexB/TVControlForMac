// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// PLACEHOLDER — the public surface only, so AndroidTvController can be written against it.
// The real implementation (a port of TVControlForWin's Services/AdbBrightness.cs) replaces
// this file. Keep these member names and signatures.

/// Brightness for one Android TV over ADB: the one-time setup, the connection, and
/// debounced writes. Owned by `AndroidTvController`, which tells it when the TV comes and goes.
final class AdbBrightness {
    private let device: TvDevice

    /// - Parameters:
    ///   - deviceChanged: called after something persisted on the device changed.
    ///   - tvIsOn: whether the TV is connected and switched on right now.
    init(device: TvDevice, deviceChanged: @escaping () -> Void, tvIsOn: @escaping () -> Bool) {
        self.device = device
    }

    private(set) var state: BrightnessSetup = .unknown

    /// True when a value passed to `set` won't be lost even though brightness isn't `.ready`.
    var holds: Bool { !device.adbKey.isEmpty && state != .unsupported }

    /// Fires whenever `state` changes (any thread).
    var onStateChanged: (() -> Void)?
    /// Fires with the TV's current brightness when it's read (any thread).
    var onReported: ((Int) -> Void)?

    /// The TV just connected.
    func resume(mightSupport: Bool) async {
        if state == .unknown || state == .unavailable {
            state = .unavailable
            onStateChanged?()
        }
    }

    /// The user asked for brightness: connect, getting the TV's approval if it doesn't know us.
    func setUp() async {}

    /// The TV went away (connection lost or standby).
    func suspend() {}

    /// The TV reported its power state.
    func tvPowerChanged(on: Bool) {}

    /// Queues a brightness change; only the latest value within the debounce window is sent.
    func set(_ value: Int) {}

    func dispose() {}
}
