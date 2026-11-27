import SwiftUI

/// The TVs page: add TVs (discovery or by IP), per-TV brightness, power, and the link
/// between each TV and the physical display it drives. Linking targets the hotkeys and
/// the OSD, and can pause automation while the display isn't connected to this Mac.
struct HomeView: View {
    @Bindable private var state = AppState.shared
    @State private var showDiscover = false
    @State private var showAddByIp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TVs").font(.largeTitle.bold())
                    Text("Drag a slider to set OLED Light. Link each TV to the display it drives — hotkeys and the OSD find it there, and automation can pause while it's unplugged.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if state.networkPermissionSuspected {
                    NetworkPermissionBanner()
                }

                HStack(spacing: 8) {
                    Button {
                        showDiscover = true
                    } label: {
                        Label("Find TVs", systemImage: "magnifyingglass")
                    }
                    Button {
                        showAddByIp = true
                    } label: {
                        Label("Add by IP", systemImage: "plus")
                    }
                    .popover(isPresented: $showAddByIp, arrowEdge: .bottom) {
                        AddByIpForm()
                    }
                    Spacer()
                    if state.screens.count > 1 {
                        Button {
                            DisplayIdentifier.flash()
                        } label: {
                            Label("Identify displays", systemImage: "display.2")
                        }
                        .help("Briefly shows each display's name on that display, so you can tell which is which when linking.")
                    }
                }
            }
            .padding(24)
            .padding(.bottom, state.tvs.isEmpty ? 0 : -12)
            .frame(maxWidth: 720, alignment: .leading)

            if state.tvs.isEmpty {
                ContentUnavailableView {
                    Label("No TVs yet", systemImage: "tv")
                } description: {
                    Text("Scan your network, or add one by IP address. Make sure “LG Connect Apps” is enabled on the TV (Settings → Network).")
                } actions: {
                    Button("Find TVs") { showDiscover = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.tvs) { tv in
                        TvCard(tv: tv)
                            .frame(maxWidth: 672, alignment: .leading)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 24, bottom: 6, trailing: 24))
                    }
                    .onMove { source, destination in
                        state.moveTvs(from: source, to: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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

/// Popover form for adding a TV by name + IP (replaces the always-visible field row).
private struct AddByIpForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a TV by IP address")
                .font(.headline)
            TextField("Name (e.g. Living Room C3)", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("IP address (e.g. 192.168.1.42)", text: $host)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Shown on the TV under Network settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Add TV") {
                    AppState.shared.addTv(name: name, host: host)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct TvCard: View {
    @Bindable var tv: TvState
    @State private var confirmRemove = false
    private var state: AppState { AppState.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            brightnessRow
            Divider()
            linkRow
            if tv.automationPaused {
                pausedNotice
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.45))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            state.setActive(tv)
        }
        .confirmationDialog("Remove “\(tv.name)”?", isPresented: $confirmRemove) {
            Button("Remove TV", role: .destructive) {
                state.removeTv(tv)
            }
        } message: {
            Text("Its pairing key is deleted too — adding it back will show the accept prompt on the TV again.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tv.isConnected ? AnyShapeStyle(.tint) : AnyShapeStyle(.gray.opacity(0.55)))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "tv")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tv.name)
                        .font(.headline)
                    if tv.isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.2), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(tv.isConnected ? Color.green : Color.gray.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text(tv.statusText)
                    Text("·")
                    Text(tv.host)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
            .help("Turn the TV off when it's on, wake it when it's off")
            Menu {
                Button("Remove TV…", role: .destructive) {
                    confirmRemove = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var brightnessRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max")
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { Double(tv.backlight) },
                set: { tv.backlight = Int($0.rounded()) }
            ), in: 0...100)
            Text("\(tv.backlight)%")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    // The TV ↔ display link: which physical display this TV is, whether it's currently
    // connected, and the per-TV automation gate.
    private var linkRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "display")
                .foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { tv.linkedScreenId },
                set: { state.linkDisplay(tv, screenId: $0) }
            )) {
                Text("No linked display").tag("")
                if !tv.linkedScreenId.isEmpty,
                   !state.screens.contains(where: { $0.id == tv.linkedScreenId }) {
                    Text(tv.linkedScreenName.isEmpty
                         ? "Previously linked display"
                         : tv.linkedScreenName)
                        .tag(tv.linkedScreenId)
                }
                ForEach(state.screens) { screen in
                    Text(screen.name).tag(screen.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("The physical display this TV drives. Hotkeys target the TV when the cursor is on it, and the OSD can appear there.")

            if !tv.linkedScreenId.isEmpty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(tv.displayConnected ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(tv.displayConnected ? "Connected" : "Not connected")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Automate only while connected", isOn: $tv.automationGate)
                .font(.caption)
                .disabled(tv.linkedScreenId.isEmpty)
                .help("Schedules, power rules and single-TV hotkeys skip this TV while its linked display isn't connected to this Mac — so nothing reaches the TV when the Mac isn't plugged into it. Manual controls always work.")
        }
    }

    private var pausedNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
            Text("Automation paused — \(tv.linkedScreenName.isEmpty ? "its linked display" : tv.linkedScreenName) isn't connected. Manual controls still work.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Shown when TVs are repeatedly unreachable — on macOS the usual culprit is the Local
/// Network permission being off (or never granted), so guide the user straight there.
struct NetworkPermissionBanner: View {
    private let state = AppState.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text("Can't reach your TVs")
                    .font(.headline)
                Text("If they're on, macOS may be blocking TVControlForMac's network access. Check Privacy & Security → Network (and Local Network) and enable TVControlForMac, or request the permission prompt again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Privacy Settings") {
                        state.openLocalNetworkSettings()
                    }
                    Button("Request access") {
                        state.requestLocalNetworkAccess()
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The "Find TVs" sheet: live SSDP scan results with one-click add.
struct DiscoverSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let state = AppState.shared

    @State private var discovered: [DiscoveredTv] = []
    @State private var added: Set<String> = []
    @State private var scanning = false
    @State private var statusText = "Searching for LG TVs…"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Find TVs").font(.title3.bold())
                if scanning {
                    ProgressView().controlSize(.small)
                }
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            List(discovered) { tv in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tv.name).font(.system(size: 13, weight: .semibold))
                        Text(tv.model.isEmpty || tv.model == tv.name ? tv.host : "\(tv.host)  ·  \(tv.model)")
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
            .frame(minHeight: 180)

            HStack {
                Button("Scan again") {
                    Task { await scan() }
                }
                .disabled(scanning)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440, height: 340)
        .task { await scan() }
    }

    private func scan() async {
        guard !scanning else { return }
        scanning = true
        discovered = []
        statusText = "Searching for LG TVs…"

        let found = await SsdpDiscovery.findTvs { tv in
            if !discovered.contains(where: { $0.host == tv.host }) {
                discovered.append(tv)
            }
        }
        for tv in found where !discovered.contains(where: { $0.host == tv.host }) {
            discovered.append(tv)
        }

        statusText = switch discovered.count {
        case 0: "No TVs found. Check that the TV is on (not in standby) and connected to the same network."
        case 1: "1 TV found."
        case let n: "\(n) TVs found."
        }
        scanning = false
    }
}
