// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Schedule

/// Up to 10 daily brightness rules, each for all TVs or chosen ones.
struct ScheduleView: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        SettingsPage("Schedule") {
            SettingsGroup {
                ToggleRow("Apply current schedule at startup",
                          info: "When the app starts, each TV is set to the schedule in effect at that moment. That covers schedules that ran while the Mac was off.",
                          isOn: $state.applyScheduleOnStartup)
            }

            SettingsGroup("Schedules") {
                if state.settings.schedules.isEmpty {
                    Text("No schedules yet")
                        .foregroundStyle(.secondary)
                }
                ForEach($state.settings.schedules) { $schedule in
                    ScheduleRow(schedule: $schedule)
                }
                Button {
                    state.addSchedule()
                } label: {
                    Label("Add Schedule", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!state.canAddSchedule)
                .help(state.canAddSchedule ? "" : "Up to 10 schedules")
            }
        }
        // Back in time order once nobody is editing a row.
        .onAppear { state.sortSchedules() }
        .onDisappear { state.sortSchedules() }
    }
}

private struct ScheduleRow: View {
    @Binding var schedule: BrightnessSchedule
    private var state: AppState { AppState.shared }

    var body: some View {
        HStack(spacing: 12) {
            DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .fixedSize()
                .opacity(schedule.enabled ? 1 : 0.5)

            Slider(value: Binding(
                get: { Double(schedule.brightness) },
                set: { schedule.brightness = Int($0.rounded()); state.persistSchedules() }
            ), in: 0...100)
            .labelsHidden()
            .accessibilityLabel("Brightness")
            .opacity(schedule.enabled ? 1 : 0.5)

            Text("\(schedule.brightness)%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
                .opacity(schedule.enabled ? 1 : 0.5)

            if state.showsTargetPicker(for: schedule) {
                targetMenu
            }

            Toggle("Enabled", isOn: Binding(
                get: { schedule.enabled },
                set: { schedule.enabled = $0; state.persistSchedules() }
            ))
            .labelsHidden()
            .controlSize(.small)

            Button {
                state.removeSchedule(schedule)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove schedule")
            .accessibilityLabel("Remove schedule")
        }
    }

    // Which TVs this schedule changes: all of them, or the ticked ones. Only TVs whose
    // brightness can be set right now are offered.
    private var targetMenu: some View {
        Menu {
            Toggle("All TVs", isOn: Binding(
                get: { schedule.tvIds.isEmpty },
                set: { _ in toggleTarget(nil) }
            ))
            Divider()
            ForEach(state.tvs.filter(\.supportsBrightness)) { tv in
                Toggle(tv.name, isOn: Binding(
                    get: { schedule.tvIds.contains(tv.id) },
                    set: { _ in toggleTarget(tv.id) }
                ))
            }
        } label: {
            Text(RuleTargets.targetLabel(schedule.tvIds, tvs: state.tvInfos))
        }
        .fixedSize()
        .help("TVs this schedule changes")
    }

    private func toggleTarget(_ tvId: String?) {
        schedule.tvIds = RuleTargets.toggleTarget(schedule.tvIds, tvId: tvId)
        state.persistSchedules()
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                schedule.hour = Calendar.current.component(.hour, from: date)
                schedule.minute = Calendar.current.component(.minute, from: date)
                state.persistSchedules()
            }
        )
    }
}

// MARK: - Power

/// TV power automation: follow the Mac's startup, sleep, shutdown and display sleep.
/// One set of rules for all TVs, or separate rules for a TV.
struct PowerView: View {
    @Bindable private var state = AppState.shared
    /// Whose rules are shown: "" for all TVs, otherwise a TV's id.
    @State private var scope = ""

    private var scopeTv: TvState? { state.tv(withId: scope) }
    private var editable: Bool { state.powerRulesEditable(scope: scope) }

    var body: some View {
        SettingsPage("Power") {
            if state.showsPowerScope {
                SettingsGroup {
                    PickerRow("Rules for", selection: $scope) {
                        ForEach(state.powerScopes) { choice in
                            Text(choice.name).tag(choice.id)
                        }
                    }
                    if let tv = scopeTv {
                        ToggleRow("Separate rules for this TV",
                                  subtitle: "When off, it follows the rules for All TVs",
                                  isOn: Binding(
                                      get: { tv.ownPower != nil },
                                      set: { state.setSeparatePowerRules($0, for: tv) }
                                  ))
                    }
                }
            }

            Group {
                SettingsGroup("Turn On", info: "LG: on the TV, turn on Quick Start+ and “Turn on via Wi-Fi”. They're under General > Devices, or General > External Devices on some models. Then let the app connect once while the TV is on.\n\nGoogle TV: on the TV, set Settings > System > Power & Energy > Energy Modes to “Increased (Always connected)”, so it stays reachable in standby.") {
                    ToggleRow("When the app starts", subtitle: "At login, if Launch at login is on",
                              isOn: rule(\.onAppStart))
                    ToggleRow("When the Mac wakes", isOn: rule(\.onResume))
                }

                SettingsGroup("Turn Off") {
                    ToggleRow("When the Mac sleeps", isOn: rule(\.offOnSleep))
                    ToggleRow("When the Mac shuts down", subtitle: "Also on restart and log out",
                              isOn: rule(\.offOnShutdown))
                }

                SettingsGroup("Display Sleep", info: "Screen off: the picture goes dark but the TV stays on, so it comes back instantly. Google TVs can't do this and turn off instead.\n\nTurn off: saves more power. The TV takes a few seconds to come back.\n\nMost LG TVs turn themselves off a few minutes after the picture stops, even with Screen off. Keep “Turn on via Wi-Fi” on so the app can wake them.") {
                    ToggleRow("When the displays turn off", isOn: rule(\.followDisplayOff))
                    PickerRow("What the TV does", selection: rule(\.displayOffAction)) {
                        Text("Screen off").tag(0)
                        Text("Turn off").tag(1)
                    }
                    .disabled(!state.powerRules(scope: scope).followDisplayOff)
                    ToggleRow("When the displays turn back on", isOn: rule(\.followDisplayOn))
                }
            }
            // A TV that follows the shared rules shows them without changing them.
            .disabled(!editable)
        }
        .onChange(of: state.showsPowerScope) {
            // With the chooser hidden there'd be no way back from one TV's view, e.g.
            // after the other TV was removed: go back to the shared rules.
            if !state.showsPowerScope { scope = "" }
        }
        .onChange(of: state.tvs.map(\.id)) {
            if scopeTv == nil { scope = "" }
        }
        // After a settings import the page goes back to the shared rules, now the restored ones.
        .onChange(of: state.reloads) { scope = "" }
    }

    private func rule<Value>(_ keyPath: WritableKeyPath<PowerSettings, Value>) -> Binding<Value> {
        Binding(
            get: { state.powerRules(scope: scope)[keyPath: keyPath] },
            set: { newValue in
                var rules = state.powerRules(scope: scope)
                rules[keyPath: keyPath] = newValue
                state.setPowerRules(rules, scope: scope)
            }
        )
    }
}

// MARK: - Hotkeys

/// Global brightness hotkeys: the modifier keys, the step, and which TV they change.
struct HotkeysView: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        SettingsPage("Hotkeys") {
            SettingsGroup {
                SettingRow("Shortcut",
                           info: "Hold these keys and press the Up or Down arrow to change brightness. At least one key stays selected.") {
                    HStack(spacing: 6) {
                        modifier("⌃", "Control", $state.hotkeyControl)
                        modifier("⌥", "Option", $state.hotkeyOption)
                        modifier("⇧", "Shift", $state.hotkeyShift)
                        modifier("⌘", "Command", $state.hotkeyCommand)
                        Text("+  ↑ / ↓")
                            .foregroundStyle(.secondary)
                    }
                }

                SettingRow("Brightness step") {
                    Slider(value: Binding(
                        get: { Double(state.hotkeyStep) },
                        set: { state.hotkeyStep = Int($0.rounded()) }
                    ), in: 1...25)
                    .labelsHidden()
                    .frame(width: 180)
                    .accessibilityLabel("Brightness step")
                    Text("\(state.hotkeyStep)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }

                if state.showsHotkeyTarget {
                    PickerRow("Which TV",
                              info: "“TV Under the Pointer” changes the TV on the display your pointer is on. Choose each TV's display on the Home page. On a display with no TV, nothing changes.",
                              selection: $state.hotkeyTarget) {
                        ForEach(state.hotkeyTargetChoices) { choice in
                            Text(choice.name).tag(choice.id)
                        }
                    }
                }
            }
        }
    }

    private func modifier(_ symbol: String, _ name: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(symbol, isOn: isOn)
            .toggleStyle(.button)
            .help(name)
            .accessibilityLabel(name)
    }
}

// MARK: - On-screen display

/// The brightness overlay's preferences.
struct OsdSettingsView: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        SettingsPage("On-Screen Display") {
            SettingsGroup {
                ToggleRow("Show on-screen display", isOn: osd(\.enabled))
            }

            SettingsGroup("Appearance") {
                PickerRow("Style", selection: osd(\.style)) {
                    Text("macOS").tag(0)
                    Text("Windows").tag(1)
                }
                // The macOS style always sits below the menu bar, like the system's own.
                if state.settings.osd.style == 1 {
                    PickerRow("Position", selection: osd(\.position)) {
                        Text("Bottom centre").tag(0)
                        Text("Bottom left").tag(1)
                        Text("Bottom right").tag(2)
                        Text("Top centre").tag(3)
                        Text("Top left").tag(4)
                        Text("Top right").tag(5)
                    }
                }
                PickerRow("Display",
                          info: "“The TV being adjusted” uses the display chosen on each TV's card on the Home page.",
                          selection: osd(\.monitor)) {
                    Text("Main display").tag(0)
                    Text("The TV being adjusted").tag(1)
                    Text("Display under the pointer").tag(2)
                }
                SettingRow("Duration") {
                    Slider(value: Binding(
                        get: { state.settings.osd.timeoutSeconds },
                        set: {
                            // Tenths of a second, without tick marks crowding the slider.
                            state.settings.osd.timeoutSeconds = max(0.5, min(5.0, ($0 * 10).rounded() / 10))
                            state.saveSettings()
                        }
                    ), in: 0.5...5.0)
                    .labelsHidden()
                    .frame(width: 180)
                    .accessibilityLabel("Duration")
                    Text(String(format: "%.1f s", state.settings.osd.timeoutSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                ToggleRow("Show percentage", isOn: osd(\.showPercentage))
                ToggleRow("Show TV name", isOn: osd(\.showTvName))
                ToggleRow("Show when a schedule runs", isOn: osd(\.showOnSchedule))
            }

            SettingsGroup {
                SettingRow("Preview") {
                    Button("Show") { state.previewOsd() }
                }
            }
        }
    }

    private func osd<Value>(_ keyPath: WritableKeyPath<OsdSettings, Value>) -> Binding<Value> {
        Binding(
            get: { state.settings.osd[keyPath: keyPath] },
            set: { state.settings.osd[keyPath: keyPath] = $0; state.saveSettings() }
        )
    }
}

// MARK: - Settings

/// App preferences: theme, menu bar, launch at login, backup, updates.
struct SettingsView: View {
    @Bindable private var state = AppState.shared
    @State private var dialogMessage: DialogMessage?

    struct DialogMessage: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    var body: some View {
        SettingsPage("Settings") {
            SettingsGroup("Appearance") {
                PickerRow("Theme", selection: $state.themeIndex) {
                    Text("Use system setting").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                ToggleRow("Show menu bar icon",
                          info: "Closing the window keeps the app running in the menu bar. With the icon hidden it keeps running in the background. Open the app again to get this window back.",
                          isOn: $state.showMenuBarIcon)
            }

            SettingsGroup("Startup") {
                ToggleRow("Launch at login", isOn: $state.startAtLogin)
                PickerRow("At login, show",
                          info: "Opening the app yourself always shows the window.",
                          selection: $state.launchBehavior) {
                    Text("Window").tag(0)
                    Text("Minimised window").tag(1)
                    Text("No window").tag(2)
                }
                .disabled(!state.startAtLogin)
            }

            SettingsGroup("Backup") {
                SettingRow("Settings file", subtitle: "Includes TVs, pairing and schedules") {
                    Button("Export…") { exportBackup() }
                    Button("Import…") { importBackup() }
                }
            }

            UpdatesSection(updates: state.updates)
        }
        .alert(item: $dialogMessage) { message in
            Alert(title: Text(message.title), message: Text(message.text), dismissButton: .default(Text("OK")))
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(AppInfo.name)-backup.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try state.exportSettings().write(to: url, atomically: true, encoding: .utf8)
            } catch {
                dialogMessage = DialogMessage(title: "Couldn't export", text: error.localizedDescription)
            }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let json = try String(contentsOf: url, encoding: .utf8)
                try state.importSettings(json)
                dialogMessage = DialogMessage(title: "Settings imported",
                                              text: "Your TVs and settings are restored.")
            } catch {
                dialogMessage = DialogMessage(title: "Couldn't import",
                                              text: "That file isn't a settings backup.")
            }
        }
    }
}
