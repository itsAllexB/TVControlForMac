// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Picture brightness (the "Brightness" slider, 0–100, i.e. the backlight) on TCL Google TVs,
/// through ADB.
///
/// Android's own display-brightness setting does nothing on these sets; the panel is driven by
/// TCL's picture pipeline, reached through the system service "tcl_tv_display"
/// (com.tcl.tv.display.ITvDisplayManagerService). The TV's settings app calls its
/// setBacklight(applyType, value, actType) / getBacklight() — binder transactions 100 and 101 —
/// and `service call` lets the ADB shell make the same calls.
///
/// The transaction numbers are positions in TCL's interface definition, so another firmware
/// generation could number them differently. Hence the checks: the service has to exist under
/// that interface name, the value read has to be a plausible 0–100, and the first write of a
/// connection is read back (see `set`). Worked out and tested on a 65C765 (Android 14).
enum AdbTclBacklight {
    private static let service = "tcl_tv_display"
    private static let interface = "com.tcl.tv.display.ITvDisplayManagerService"
    private static let setBacklight = 100
    private static let getBacklight = 101

    // What the TV's own settings slider sends. applyType 1 + actType 2 is the combination that
    // drives the panel and saves; 0 + 1 (what the service then calls internally) only stores
    // the number.
    private static let applyType = 1
    private static let actType = 2

    /// TVs worth offering this on, judged by the vendor name from the remote handshake.
    static func mightSupport(vendor: String) -> Bool {
        vendor.range(of: "TCL", options: .caseInsensitive) != nil
    }

    /// True when the TV has the service this relies on, under the expected interface.
    static func isAvailable(_ adb: AdbClient, until deadline: DispatchTime) async throws -> Bool {
        let listing = try await adb.shell("service list | grep \(service)", until: deadline)
        guard listing.contains(interface) else { return false }
        return try await get(adb, until: deadline) != nil
    }

    /// The current brightness, or nil if the TV's answer doesn't look like one.
    static func get(_ adb: AdbClient, until deadline: DispatchTime) async throws -> Int? {
        let reply = try await adb.shell("service call \(service) \(getBacklight)", until: deadline)
        guard let value = parseInt(reply), (0...100).contains(value) else { return nil }
        return value
    }

    enum SetResult {
        /// The TV took the value (and, when asked to verify, read it back).
        case applied
        /// The service turned the call down. Can be passing: it also happens while the TV is
        /// still waking up.
        case refused
        /// The call was accepted but the value read back is a different one: these aren't the
        /// calls we think they are on this firmware, so stop writing.
        case notApplied
    }

    /// Sets the brightness. With `verify` it also confirms the value took by reading it back.
    static func set(_ adb: AdbClient, _ value: Int, verify: Bool, until deadline: DispatchTime) async throws -> SetResult {
        let value = max(0, min(100, value))
        let reply = try await adb.shell(
            "service call \(service) \(setBacklight) i32 \(applyType) i32 \(value) i32 \(actType)", until: deadline)
        guard parseInt(reply) == 1 else { return .refused }
        if !verify { return .applied }

        // The service applies the value a moment after the call returns (~90 ms measured), so
        // an immediate read can still see the old one. Give it a few tries.
        for _ in 0..<6 {
            try await Task.sleep(nanoseconds: 120_000_000)
            if DispatchTime.now() >= deadline { throw AdbConnectionError.timedOut }
            if try await get(adb, until: deadline) == value { return .applied }
        }
        return .notApplied
    }

    // `service call` prints the reply parcel as hex words:
    //   Result: Parcel(00000000 0000003c   '....<...')
    // The first word is the exception code (0 = none), the second the return value, a
    // signed 32-bit int.
    static func parseInt(_ reply: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"Parcel\(\s*([0-9a-f]{8})\s+([0-9a-f]{8})"#),
              let match = regex.firstMatch(in: reply, range: NSRange(reply.startIndex..., in: reply)),
              match.numberOfRanges == 3,
              let codeRange = Range(match.range(at: 1), in: reply),
              let valueRange = Range(match.range(at: 2), in: reply),
              reply[codeRange] == "00000000",
              let word = UInt32(reply[valueRange], radix: 16) else { return nil }
        return Int(Int32(bitPattern: word))
    }
}
