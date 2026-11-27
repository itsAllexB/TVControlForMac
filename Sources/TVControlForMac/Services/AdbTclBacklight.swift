// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// PLACEHOLDER — replaced by the port of TVControlForWin's Services/AdbTclBacklight.cs.

/// TCL's backlight control, reached from an ADB shell.
enum AdbTclBacklight {
    /// Whether a TV from this vendor is worth offering brightness setup to.
    static func mightSupport(vendor: String) -> Bool {
        vendor.range(of: "TCL", options: .caseInsensitive) != nil
    }
}
