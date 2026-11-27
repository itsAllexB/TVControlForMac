// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The Settings page's "Updates" section: the running version with the one update button
/// (Check now, Update, Download or Install, by what's known so far), and the two switches
/// behind the daily check.
struct UpdatesSection: View {
    let updates: UpdateManager

    var body: some View {
        SettingsGroup("Updates") {
            SettingRow(updates.versionLabel,
                       icon: "arrow.triangle.2.circlepath",
                       subtitle: updates.statusText.isEmpty ? nil : updates.statusText,
                       info: updates.manualReasonText) {
                if updates.offersUpdates {
                    HStack(spacing: 10) {
                        if updates.isBusy {
                            ProgressView().controlSize(.small)
                        }
                        Button(updates.buttonText) { updates.buttonPressed() }
                            .disabled(!updates.buttonEnabled)
                            .frame(minWidth: 96)
                    }
                }
            }

            if updates.offersUpdates {
                ToggleRow("Check automatically",
                          icon: "clock.arrow.circlepath",
                          info: "Looks on GitHub for a new version about once a day.",
                          isOn: Binding(get: { updates.checkAutomatically },
                                        set: { updates.setCheckAutomatically($0) }))
            }

            if updates.offersAutomaticInstall {
                ToggleRow("Install automatically",
                          icon: "square.and.arrow.down",
                          info: "A new version is downloaded in the background and installed once this window is closed. The app restarts in the background. With this off, you install it yourself from here.",
                          isOn: Binding(get: { updates.installAutomatically },
                                        set: { updates.setInstallAutomatically($0) }))
                    .disabled(!updates.checkAutomatically)
            }
        }
    }
}
