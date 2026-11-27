// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case home, schedule, power, hotkeys, osd, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .schedule: "Schedule"
        case .power: "Power"
        case .hotkeys: "Keyboard Shortcut"
        case .osd: "On-Screen Display"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "tv"
        case .schedule: "clock"
        case .power: "power"
        case .hotkeys: "keyboard"
        case .osd: "rectangle.on.rectangle"
        case .settings: "gearshape"
        }
    }
}

/// The main window: a sidebar over the six pages.
struct MainView: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        NavigationSplitView {
            List(AppPage.allCases, selection: Binding(get: { state.page }, set: { if let page = $0 { state.page = page } })) { item in
                HStack {
                    Label(item.title, systemImage: item.icon)
                    // A dot on Settings says an update is waiting there.
                    if item == .settings && state.updateReady {
                        Spacer()
                        Circle()
                            .fill(.tint)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Update ready")
                    }
                }
                .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 250)
        } detail: {
            switch state.page {
            case .home: HomeView()
            case .schedule: ScheduleView()
            case .power: PowerView()
            case .hotkeys: HotkeysView()
            case .osd: OsdSettingsView()
            case .settings: SettingsView()
            }
        }
        .toolbar { TitleBarHeightKeeper() }
        .onChange(of: state.page, initial: true) {
            (NSApp.delegate as? AppDelegate)?.setWindowTitle(state.page.title)
        }
        .frame(minWidth: 760, minHeight: 500)
    }
}

/// An invisible toolbar item. Pages without buttons of their own still get a toolbar this
/// way, so the title bar is the same height on every page.
private struct TitleBarHeightKeeper: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            // On macOS 26 every toolbar item sits on glass; this one mustn't show any.
            ToolbarItem(placement: .automatic) { placeholder }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .automatic) { placeholder }
        }
    }

    private var placeholder: some View {
        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
    }
}
