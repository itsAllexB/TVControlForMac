// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit

/// A scripted OSD request sent by `TVControlForMac --osd-preview <options>` to the running
/// app, so the OSD can be compared against the system HUD and stress-tested without TVs.
///
///   --osd-preview 30                         brightness 30, macOS style, primary display
///   --osd-preview 30 --style win             the Windows-style pill (--position 0-5 picks its anchor)
///   --osd-preview --mode unpaired            the "No TV on this screen" message
///   --osd-preview 30 --name "Living Room"    with the TV-name row
///   --osd-preview 30 --screen 1              on NSScreen.screens[1] (as "the TV's screen")
///   --osd-preview 30 --screen cursor         on the screen under the pointer
///   --osd-preview 30 --duration 3 --theme dark
///   --osd-preview 25 --glyph speaker         draw the speaker, to compare with the volume HUD
///   --osd-preview 25 --anchor fallback       ignore our menu bar item (sit where the volume HUD does)
///   --osd-preview 30 --stress 200            200 rapid shows mixing styles, modes, screens
///                                            and values, ending on a plain brightness show
struct OsdTestRequest {
    static let notification = Notification.Name("com.itsallexb.TVControlForMac.osd-test")
    static let usage = """
        usage: --osd-preview [value] [--style mac|win] [--position 0-5] [--mode brightness|unpaired|disconnected]
                             [--name TEXT] [--screen primary|cursor|<index>] [--duration SECONDS]
                             [--theme system|light|dark] [--glyph speaker|SYMBOL]
                             [--anchor item|fallback] [--stress COUNT]
        """

    var value = 50
    var style = 0
    var position = 0
    var mode = "brightness"
    var name: String?
    var screen = "primary"
    var duration = 1.6
    var theme: String?
    var glyph: String?
    var anchor: String?
    var stress = 0

    init?(arguments: [String]) {
        var it = arguments.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--style": guard let v = it.next() else { return nil }; style = v == "win" ? 1 : 0
            case "--position": guard let v = it.next().flatMap(Int.init) else { return nil }; position = v
            case "--mode":
                guard let v = it.next(), ["brightness", "unpaired", "disconnected"].contains(v) else { return nil }
                mode = v
            case "--name": guard let v = it.next() else { return nil }; name = v
            case "--screen": guard let v = it.next() else { return nil }; screen = v
            case "--duration": guard let v = it.next().flatMap(Double.init) else { return nil }; duration = v
            case "--theme": guard let v = it.next() else { return nil }; theme = v
            case "--glyph": guard let v = it.next() else { return nil }; glyph = v
            case "--anchor": guard let v = it.next() else { return nil }; anchor = v
            case "--stress": guard let v = it.next().flatMap(Int.init) else { return nil }; stress = v
            default:
                guard let v = Int(arg) else { return nil }
                value = v
            }
        }
    }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo else { return nil }
        value = info["value"] as? Int ?? value
        style = info["style"] as? Int ?? style
        position = info["position"] as? Int ?? position
        mode = info["mode"] as? String ?? mode
        name = info["name"] as? String
        screen = info["screen"] as? String ?? screen
        duration = info["duration"] as? Double ?? duration
        theme = info["theme"] as? String
        glyph = info["glyph"] as? String
        anchor = info["anchor"] as? String
        stress = info["stress"] as? Int ?? stress
    }

    // Distributed notifications only carry property-list values.
    var userInfo: [String: Any] {
        var info: [String: Any] = ["value": value, "style": style, "position": position, "mode": mode, "screen": screen,
                                   "duration": duration, "stress": stress]
        if let name { info["name"] = name }
        if let theme { info["theme"] = theme }
        if let glyph { info["glyph"] = glyph }
        if let anchor { info["anchor"] = anchor }
        return info
    }
}

extension OsdController {
    /// Listens for `OsdTestRequest`s. Diagnostics only: it shows an OSD and changes nothing else.
    func installTestHook() {
        DistributedNotificationCenter.default().addObserver(
            forName: OsdTestRequest.notification, object: nil, queue: .main
        ) { [weak self] note in
            guard let request = OsdTestRequest(userInfo: note.userInfo) else { return }
            Task { @MainActor in self?.runTest(request) }
        }
    }

    private func runTest(_ request: OsdTestRequest) {
        switch request.theme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "system": NSApp.appearance = nil
        default: break
        }
        // Only the comparison runs swap the glyph; every other request restores the sun.
        systemHudSymbol = request.glyph == "speaker" ? "speaker.wave.2.fill" : (request.glyph ?? "sun.max.fill")
        systemHudIgnoresMenuBarItem = request.anchor == "fallback"
        if request.stress > 0 {
            stressFailures = 0
            runStress(request, remaining: request.stress, seed: 0x5EED)
        } else {
            show(request)
        }
    }

    private func show(_ request: OsdTestRequest) {
        var osd = OsdSettings()
        osd.style = request.style
        osd.position = request.position
        osd.timeoutSeconds = request.duration
        osd.showTvName = request.name != nil
        var screenId: String?
        switch request.screen {
        case "cursor":
            osd.monitor = 2
        case "primary":
            osd.monitor = 0
        default:
            // An index into NSScreen.screens, presented as "the adjusted TV's screen".
            osd.monitor = 1
            if let index = Int(request.screen), NSScreen.screens.indices.contains(index) {
                screenId = ScreenService.stableId(for: NSScreen.screens[index])
            }
        }
        switch request.mode {
        case "unpaired": showUnpaired(osd: osd)
        case "disconnected": showDisconnected(osd: osd)
        default:
            showBrightness(tvName: request.name, value: request.value, osd: osd, screenId: screenId,
                           allowFallback: true)
        }
    }

    // Hammers the OSD with the transitions that used to leave it empty: style and mode
    // switches, other screens, and shows landing mid-entrance or mid-exit. Deterministic
    // (fixed seed) so a failure can be replayed; the last show is the plain request.
    // After every step it checks that whichever OSD is up still shows its content, and
    // reports the tally on stderr when done.
    private func runStress(_ base: OsdTestRequest, remaining: Int, seed: UInt64) {
        guard remaining > 1 else {
            show(base)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                if !self.osdContentIsAttached { self.stressFailures += 1 }
                FileHandle.standardError.write(Data(
                    "OSD stress: \(base.stress) shows, \(self.stressFailures) with the content missing\n".utf8))
            }
            return
        }
        var rng = seed &* 6364136223846793005 &+ 1442695040888963407
        func next(_ n: Int) -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) % UInt64(n))
        }
        var step = base
        step.style = next(4) == 0 ? 1 - base.style : base.style
        step.mode = ["brightness", "brightness", "brightness", "unpaired", "disconnected"][next(5)]
        step.value = next(101)
        step.name = next(3) == 0 ? "Living Room" : nil
        step.screen = next(4) == 0 ? String(next(max(1, NSScreen.screens.count))) : base.screen
        step.duration = 0.5
        show(step)
        if !osdContentIsAttached { stressFailures += 1 }
        // Gaps from "same frame" to "well into the exit animation".
        let delay = [0.0, 0.016, 0.05, 0.12, 0.3, 0.55, 0.7][next(7)]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runStress(base, remaining: remaining - 1, seed: rng)
        }
    }
}

@MainActor private var stressFailureCount = 0

private extension OsdController {
    var stressFailures: Int {
        get { stressFailureCount }
        set { stressFailureCount = newValue }
    }
}
