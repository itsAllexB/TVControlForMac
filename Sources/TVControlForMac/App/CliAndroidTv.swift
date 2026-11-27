// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Hidden diagnostics commands for Google TV (Android TV Remote protocol). `CliMode` hands over any argument
/// listed in `commands`.
enum AtvCli {
    /// The first-argument flags this handles, e.g. "--example".
    static let commands: Set<String> = []

    /// Runs the command in `args` (args[0] is the flag). Prints its own output.
    static func run(_ args: [String]) async {
    }
}
