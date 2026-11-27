// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The Home page: one group per TV (brightness, power, pairing, and the display it's
/// linked to), with finding and adding TVs in the toolbar.
struct HomeView: View {
    @Bindable private var state = AppState.shared
    @State private var showDiscover = false
    @State private var showAddByIp = false

    var body: some View {
        SettingsPage("Home") {
            if state.networkPermissionSuspected {
                NetworkPermissionNotice()
            }
            ForEach(state.tvs) { tv in
                TvGroup(tv: tv)
            }
        }
        .overlay {
            if state.tvs.isEmpty {
                ContentUnavailableView {
                    Label("No TVs Yet", systemImage: "tv")
                } description: {
                    Text("Search your network, or add a TV by its IP address.")
                } actions: {
                    Button("Find TVs") { showDiscover = true }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if state.screens.count > 1 {
                    Button {
                        DisplayIdentifier.flash()
                    } label: {
                        Label("Identify Displays", systemImage: "display.2")
                    }
                    .help("Show each display's name on that display")
                }
                Button {
                    showAddByIp = true
                } label: {
                    Label("Add by IP Address", systemImage: "plus")
                }
                .help("Add a TV by its IP address")
                .popover(isPresented: $showAddByIp, arrowEdge: .bottom) {
                    AddByIpForm(isPresented: $showAddByIp)
                }
                Button {
                    showDiscover = true
                } label: {
                    Label("Find TVs", systemImage: "magnifyingglass")
                }
                .help("Search your network for TVs")
            }
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverSheet()
        }
        .onAppear {
            state.refreshScreens() // freshly (un)plugged displays appear on revisit
            state.updateDisplayPresence()
        }
    }
}

/// Popover form for adding a TV by its address. The brand is worked out from the ports
/// the TV answers on, so there's nothing to pick.
private struct AddByIpForm: View {
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var host = ""
    @State private var error = ""
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a TV")
                .font(.headline)
            TextField("IP address", text: $host)
                .textFieldStyle(.roundedBorder)
                .onChange(of: host) { error = "" } // typing a different address clears the message
            TextField("Name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
            if !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if adding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Add TV") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(adding || host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func add() {
        adding = true
        Task {
            let problem = await AppState.shared.addTv(name: name, host: host)
            adding = false
            if let problem {
                error = problem
            } else {
                isPresented = false
            }
        }
    }
}

/// One TV: its name and state, brightness, and whatever it still needs (pairing,
/// brightness setup, a display to be linked to).
private struct TvGroup: View {
    @Bindable var tv: TvState
    @State private var confirmRemove = false
    private var state: AppState { AppState.shared }

    var body: some View {
        Section {
            header
            if tv.showsSlider {
                brightnessRow
            }
            if tv.showsPairing {
                pairingRow
            }
            if tv.showsBrightnessSetup {
                brightnessSetupRow
            }
            displayRow
            if !tv.linkedScreenId.isEmpty {
                ToggleRow("Automate only while connected",
                          subtitle: tv.automationPaused ? "Paused while its display isn't connected" : nil,
                          info: "Schedules, power rules and the keyboard shortcut leave this TV alone while its display isn't connected to this Mac, for example when a MacBook is away from the desk. The controls on this page always work.",
                          isOn: $tv.automationGate)
            }
        }
        .confirmationDialog("Remove “\(tv.name)”?", isPresented: $confirmRemove) {
            Button("Remove TV", role: .destructive) {
                state.removeTv(tv)
            }
        } message: {
            Text("Its pairing is removed too.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tv.isConnected ? AnyShapeStyle(.tint) : AnyShapeStyle(.gray.opacity(0.5)))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "tv")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(tv.name)
                    .font(.headline)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(tv.statusHelp ?? "")
            }

            Spacer()

            if tv.isBusy {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await tv.togglePower() }
            } label: {
                Image(systemName: "power")
            }
            .help("Turn on or off")
            .accessibilityLabel("Turn \(tv.name) on or off")

            Menu {
                Button("Move Up") { move(by: -1) }
                    .disabled(state.tvs.first === tv)
                Button("Move Down") { move(by: 1) }
                    .disabled(state.tvs.last === tv)
                Divider()
                Button("Remove TV…", role: .destructive) { confirmRemove = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More for \(tv.name)")
        }
    }

    // "192.168.1.159 · LG webOS · Connected", plus " · Power only" for a TV whose
    // brightness can't be controlled, so the missing slider doesn't look like a fault.
    private var detailLine: String {
        var parts = [tv.host, tv.kindLabel]
        if tv.isPowerOnly { parts.append("Power only") }
        parts.append(tv.statusText)
        return parts.joined(separator: " · ")
    }

    private func move(by offset: Int) {
        guard let index = state.tvs.firstIndex(where: { $0 === tv }) else { return }
        let target = index + offset
        guard state.tvs.indices.contains(target) else { return }
        state.moveTvs(from: IndexSet(integer: index), to: offset > 0 ? target + 1 : target)
    }

    private var brightnessRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.min")
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { Double(tv.backlight) },
                set: { tv.backlight = Int($0.rounded()) }
            ), in: 0...100)
            .labelsHidden()
            .accessibilityLabel("Brightness")
            Image(systemName: "sun.max")
                .foregroundStyle(.secondary)
            Text("\(tv.backlight)%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    // Google TVs pair with a code the TV shows. While a code is awaited, the card's
    // status line already says what to do (or what was wrong with the last one).
    private var pairingRow: some View {
        SettingRow("Pair with this TV",
                   subtitle: tv.awaitingCode ? nil : "The TV will show a code to type here") {
            if tv.awaitingCode {
                TextField("Code", text: $tv.pairingCode, prompt: Text("Code"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 90)
                    .onSubmit { tv.advancePairing() }
            }
            Button(tv.awaitingCode ? "Confirm" : "Pair") {
                tv.advancePairing()
            }
        }
    }

    // Brightness on a Google TV goes over ADB, which the owner switches on once.
    private var brightnessSetupRow: some View {
        SettingRow("Brightness", subtitle: tv.brightnessSetupText, info: TvState.brightnessSetupHelp) {
            if tv.brightnessSetupBusy {
                ProgressView().controlSize(.small)
            }
            if let title = tv.brightnessSetupButtonText {
                Button(title) { tv.setUpBrightness() }
            }
        }
    }

    // Which display this TV is: the hotkeys and the on-screen display find it there.
    private var displayRow: some View {
        PickerRow("Display",
                  subtitle: !tv.linkedScreenId.isEmpty && !tv.displayConnected ? "Not connected" : nil,
                  info: "Choose which display this TV is. The keyboard shortcut then changes the TV under your pointer, and the on-screen display shows on the right TV.",
                  selection: Binding(
                      get: { tv.linkedScreenId },
                      set: { state.linkDisplay(tv, screenId: $0) }
                  )) {
            Text("None").tag("")
            if !tv.linkedScreenId.isEmpty,
               !state.screens.contains(where: { $0.id == tv.linkedScreenId }) {
                Text(tv.linkedScreenName.isEmpty ? "Previous display" : tv.linkedScreenName)
                    .tag(tv.linkedScreenId)
            }
            ForEach(state.screens) { screen in
                Text(screen.name).tag(screen.id)
            }
        }
    }
}

/// Shown when TVs are repeatedly unreachable. On macOS the usual culprit is the Local
/// Network permission being off (or never granted), so point straight at it.
private struct NetworkPermissionNotice: View {
    private let state = AppState.shared

    var body: some View {
        Section {
            SettingRow("Can't reach your TVs",
                       subtitle: "macOS may be blocking local network access",
                       info: "If the TVs are on, check System Settings > Privacy & Security > Local Network and allow \(AppInfo.name). If it isn't listed there, select Ask Again and macOS will show its permission prompt.") {
                Button("Ask Again") { state.requestLocalNetworkAccess() }
                Button("Open Settings") { state.openLocalNetworkSettings() }
            }
        }
    }
}

/// The "Find TVs" sheet: live scan results with one-click add.
struct DiscoverSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let state = AppState.shared

    @State private var discovered: [DiscoveredTv] = []
    @State private var added: Set<String> = []
    @State private var scanning = false
    @State private var statusText = "Searching…"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Find TVs").font(.title3.bold())
                Spacer()
                if scanning {
                    ProgressView().controlSize(.small)
                }
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            List(discovered) { tv in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tv.name).fontWeight(.medium)
                        Text(details(for: tv))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if added.contains(tv.host) || state.hasTv(host: tv.host) {
                        Text("Added").foregroundStyle(.secondary)
                    } else {
                        Button("Add") {
                            state.addDiscoveredTv(tv)
                            added.insert(tv.host)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 190)
            .overlay {
                if discovered.isEmpty && !scanning {
                    Text("Make sure the TV is on and on the same network as this Mac")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Search Again") {
                    Task { await scan() }
                }
                .disabled(scanning)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440, height: 350)
        .task { await scan() }
    }

    // "192.168.1.154 · Smart TV Pro · Google TV"
    private func details(for tv: DiscoveredTv) -> String {
        var parts = [tv.host]
        if !tv.model.isEmpty && tv.model != tv.name { parts.append(tv.model) }
        parts.append(tv.kind.label)
        return parts.joined(separator: " · ")
    }

    private func scan() async {
        guard !scanning else { return }
        scanning = true
        discovered = []
        statusText = "Searching…"

        let found = await SsdpDiscovery.findTvs { tv in
            if !discovered.contains(where: { $0.host == tv.host }) {
                discovered.append(tv)
            }
        }
        for tv in found where !discovered.contains(where: { $0.host == tv.host }) {
            discovered.append(tv)
        }

        statusText = switch discovered.count {
        case 0: "No TVs found"
        case 1: "1 TV found"
        case let n: "\(n) TVs found"
        }
        scanning = false
    }
}
