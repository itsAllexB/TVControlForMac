// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import ServiceManagement

/// Opt-in "launch at login" via `SMAppService.mainApp`, the standard mechanism, so the
/// app appears under System Settings → General → Login Items → "Open at Login" like any
/// other app. An at-login launch is detected from the Apple event macOS tags login-item
/// launches with, so the launch-behavior preference (normal / minimized / background)
/// only applies to autostart launches.
enum AutostartService {
    /// True when this process was launched by the login item rather than the user.
    /// Only meaningful during app startup; the launch Apple event is current then.
    static var isAutostartLaunch: Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           let prop = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)),
           prop.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        return false
    }

    static func apply(_ enabled: Bool) {
        // An instance running on its own data folder is a side-by-side trial; it must not
        // take over (or remove) the real installation's login item.
        if AppPaths.isTrialRun { return }

        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            Log.write("autostart: \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }
}
