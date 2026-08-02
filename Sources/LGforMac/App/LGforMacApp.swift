import SwiftUI

// The entry point must be SYNCHRONOUS: an async main() would run NSApplicationMain
// inside one never-ending main-actor task, permanently starving every other
// `Task { @MainActor … }` in the app (UI status updates would silently never run).
@main
enum Entry {
    static func main() {
        if CliMode.isRequested {
            Task.detached {
                _ = await CliMode.runIfRequested()
                exit(0)
            }
            dispatchMain() // service the main queue for the CLI's MainActor hops
        }
        LGforMacApp.main()
    }
}

struct LGforMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // isInserted honors the "Show the menu bar icon" setting; the getter runs inside
        // SwiftUI's observation tracking, so toggling it inserts/removes the item live.
        // The setter also covers macOS removing the item itself (⌘-drag off the bar).
        MenuBarExtra(isInserted: Binding(
            get: { AppState.shared.settings.showMenuBarIcon },
            set: { AppState.shared.showMenuBarIcon = $0 }
        )) {
            MenuBarView()
        } label: {
            Image(systemName: "sun.max.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    /// Set once services are running; a duplicate instance that terminates early must NOT
    /// run the shutdown path (its fresh AppState would overwrite the primary's state files).
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a second launch just surfaces the one already running.
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.itsallexb.LGforMac")
        if running.count > 1 {
            running.first { $0 != .current }?.activate()
            NSApp.terminate(nil)
            return
        }

        let state = AppState.shared
        state.start()
        started = true

        // Manual launches always open the window; the launch-behavior preference applies
        // only to the at-login autostart launch (tagged with --autostart by the agent).
        let behavior = AutostartService.isAutostartLaunch ? state.settings.launchBehavior : 0
        switch behavior {
        case 2:
            break // in the background — stays an accessory (no window, no Dock icon)
        case 1:
            showMainWindow(activate: false)
            windowController?.window?.miniaturize(nil)
        default:
            showMainWindow(activate: !AutostartService.isAutostartLaunch)
        }
    }

    // Closing the window keeps the app alive in the menu bar (parity with hide-to-tray).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Clicking the Dock icon (or reopening) surfaces the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard started else { return }
        AppState.shared.shutdown()
    }

    func showMainWindow(activate: Bool = true) {
        // The app runs as an accessory (LSUIElement, no Dock icon); opening the window
        // is what promotes it to a regular app so it behaves normally while visible.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        if windowController == nil {
            windowController = MainWindowController()
        }
        windowController?.showWindow(nil)
        if activate {
            // After a policy switch, activation only sticks from the next runloop turn.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// The main settings window: an AppKit window hosting the SwiftUI MainView, so launch
/// behavior (hidden / minimized), close-to-menu-bar and show-from-menu-bar stay fully
/// under our control.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let hosting = NSHostingController(rootView: MainView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "LGforMac"
        window.setContentSize(NSSize(width: 900, height: 640))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.contentMinSize = NSSize(width: 780, height: 520)
        window.setFrameAutosaveName("LGforMacMain")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
    }

    // Close hides to the background instead of quitting (parity with LGforWin's tray
    // icon), and drops the Dock icon — a closed LGforMac is a plain menu bar app.
    // Relaunching the app (or clicking the menu bar icon's "Open LGforMac") reopens it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }
}
