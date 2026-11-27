// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The menu bar popover: a brightness slider and power button for every TV.
struct MenuBarView: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.networkPermissionSuspected {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text("Can't reach your TVs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Fix…") {
                        state.page = .home
                        (NSApp.delegate as? AppDelegate)?.showMainWindow()
                    }
                    .controlSize(.mini)
                }
            }
            if state.tvs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No TVs Yet")
                        .font(.headline)
                    Text("Open the app to add one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(state.tvs) { tv in
                    MenuBarTvRow(tv: tv)
                }
            }

            Divider()

            HStack {
                Button("Open \(AppInfo.name)") {
                    (NSApp.delegate as? AppDelegate)?.showMainWindow()
                }
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
    }
}

private struct MenuBarTvRow: View {
    @Bindable var tv: TvState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tv.isConnected ? Color.green : Color.gray.opacity(0.6))
                    .frame(width: 7, height: 7)
                Text(tv.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if tv.automationPaused {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("Automation is paused while its display isn't connected")
                }
                Spacer()
                Text(tv.supportsBrightness ? "\(tv.backlight)%" : note)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    Task { await tv.togglePower() }
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Turn on or off")
                .accessibilityLabel("Turn \(tv.name) on or off")
            }
            if tv.supportsBrightness {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(tv.backlight) },
                        set: { tv.backlight = Int($0.rounded()) }
                    ), in: 0...100)
                    .controlSize(.small)
                    .accessibilityLabel("\(tv.name) brightness")
                    Image(systemName: "sun.max")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // What stands in for the percentage on a TV without a slider.
    private var note: String {
        if tv.showsPairing { return "Not paired" }
        if tv.isPowerOnly { return "Power only" }
        return tv.isConnected ? "" : tv.statusText
    }
}
