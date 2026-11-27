// SPDX-License-Identifier: AGPL-3.0-or-later
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
        TVControlForMacApp.main()
    }
}

struct TVControlForMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // isInserted honors the "Show menu bar icon" setting; the getter runs inside
        // SwiftUI's observation tracking, so toggling it inserts/removes the item live.
        // The setter also covers macOS removing the item itself (⌘-drag off the bar).
        MenuBarExtra(isInserted: Binding(
            get: { AppState.shared.settings.showMenuBarIcon },
            set: { AppState.shared.showMenuBarIcon = $0 }
        )) {
            MenuBarView()
        } label: {
            Image(systemName: "tv")
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
        // An instance pointed at its own data folder is a separate app as far as this
        // goes: it runs next to the normal one and leaves an old LGforMac alone.
        if !AppPaths.isTrialRun {
            // Single instance: a second launch just surfaces the one already running.
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: Bundle.main.bundleIdentifier ?? AppInfo.bundleIdentifier)
            if running.count > 1 {
                running.first { $0 != .current }?.activate()
                NSApp.terminate(nil)
                return
            }
            quitLegacyApp()
        }

        let arguments = CommandLine.arguments
        let afterUpdate = arguments.contains(AppInfo.updatedArg)

        let state = AppState.shared
        if let page = Self.requestedPage(arguments) { state.page = page }
        state.start(afterUpdate: afterUpdate)
        started = true

        // Opening the app yourself always shows the window; the launch preference applies
        // only to the at-login launch.
        let behavior = AutostartService.isAutostartLaunch ? state.settings.launchBehavior : 0
        switch behavior {
        case 2:
            break // in the background: stays an accessory (no window, no Dock icon)
        case 1:
            showMainWindow(activate: false)
            windowController?.window?.miniaturize(nil)
        default:
            showMainWindow(activate: !AutostartService.isAutostartLaunch)
        }
    }

    // The app was called LGforMac up to v1.0, with its own bundle id, so macOS sees that
    // as a different app. Two copies would both grab the hotkeys and both drive the TVs,
    // so one that's still running is asked to quit; this version carries its settings over.
    private func quitLegacyApp() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.legacyBundleIdentifier) {
            Log.write("startup: asking the old LGforMac (pid \(app.processIdentifier)) to quit")
            app.terminate()
        }
    }

    // `--page schedule` opens straight on a page (home, schedule, power, hotkeys, osd, settings).
    private static func requestedPage(_ arguments: [String]) -> AppPage? {
        guard let flag = arguments.firstIndex(of: "--page"), arguments.indices.contains(flag + 1) else { return nil }
        return AppPage(rawValue: arguments[flag + 1].lowercased())
    }

    // Closing the window keeps the app alive in the menu bar.
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

    /// True while the main window is on screen (not closed to the menu bar).
    var isMainWindowVisible: Bool {
        windowController?.window?.isVisible ?? false
    }

    /// The window is titled after the page it shows, like System Settings.
    func setWindowTitle(_ title: String) {
        windowController?.window?.title = title
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

/// The main window: an AppKit window hosting the SwiftUI MainView, so launch behavior
/// (hidden / minimized), close-to-menu-bar and show-from-menu-bar stay fully under our
/// control.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let hosting = NSHostingController(rootView: MainView())
        // Lets the pages put their title and buttons in the window's toolbar.
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.title = AppState.shared.page.title
        window.setContentSize(NSSize(width: 860, height: 620))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.contentMinSize = NSSize(width: 760, height: 500)
        window.setFrameAutosaveName("TVControlForMacMain")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
    }

    // Close hides to the background instead of quitting, and drops the Dock icon: a
    // closed TVControlForMac is a plain menu bar app. Opening the app again (or the menu
    // bar icon's "Open") brings the window back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }
}
