import AppKit
import ServiceManagement

/// Opt-in "launch at login" via `SMAppService.mainApp` — the standard mechanism, so the
/// app appears under System Settings → General → Login Items → "Open at Login" like any
/// other app. An at-login launch is detected from the Apple event macOS tags login-item
/// launches with, so the launch-behavior preference (normal / minimized / menu bar only)
/// still only applies to autostart launches.
enum AutostartService {
    static let autostartArg = "--autostart"

    // Pre-1.1 builds used this bundled launch agent instead, which macOS listed under
    // "Allow in the Background" rather than "Open at Login". Kept only to unregister it
    // on upgraded installs (its plist stays in the bundle so the lookup can resolve).
    private static let legacyAgent = SMAppService.agent(plistName: "com.itsallexb.LGforMac.autostart.plist")

    /// True when this process was launched by the login item rather than the user.
    /// Only meaningful during app startup — the launch Apple event is current then.
    static var isAutostartLaunch: Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           let prop = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)),
           prop.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        // Legacy launch agent (pre-1.1) passed an explicit flag instead.
        return CommandLine.arguments.contains(autostartArg)
    }

    static func apply(_ enabled: Bool) {
        // Migrate: drop the legacy agent registration if one is still around.
        if legacyAgent.status == .enabled {
            try? legacyAgent.unregister()
            Log.write("autostart: unregistered legacy launch agent")
        }

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
