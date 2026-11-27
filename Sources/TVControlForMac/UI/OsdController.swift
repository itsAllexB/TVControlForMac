// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI
import Observation

/// Briefly shows the brightness after it's changed via global hotkeys, in one of two styles:
/// 0 = a replica of the macOS volume/brightness HUD below the menu bar (`OsdSystemHud`),
/// 1 = the TVControlForWin-style pill at one of six screen anchors.
///
/// Each style owns its own panel and view hierarchy, built once and never re-parented.
/// The old single shared panel moved one hosting view in and out of a glass view when the
/// style or mode changed, and NSGlassEffectView ignores being handed the content view it
/// already references, so after any message or Windows-style OSD the macOS-style capsule
/// came back empty for good.
@MainActor
final class OsdController {
    private let systemHud = OsdSystemHud()

    // Windows-style pill metrics (points).
    private static let winWidth: CGFloat = 230
    private static let winHeight: CGFloat = 52          // icon + bar + value
    private static let winHeightWithName: CGFloat = 72  // + TV name line
    private static let msgWidth: CGFloat = 320          // the "no TV on this screen" prompt has text
    private static let msgHeight: CGFloat = 64
    private static let edgeMargin: CGFloat = 16
    private static let bottomMargin: CGFloat = 8
    private static let slideDistance: CGFloat = 20
    // With Reduce Motion on, the pill only fades, as the system's own pop-ups do.
    private static var slide: CGFloat {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : slideDistance
    }
    private static let fadeIn: TimeInterval = 0.25
    private static let fadeOut: TimeInterval = 0.19

    private var panel: NSPanel?
    private let model = OsdModel()
    private var hideTimer: Timer?

    private var finalOrigin = NSPoint.zero
    private var anchoredTop = false
    private var visible = false
    private var hiding = false
    // Bumped on every show/hide of the pill; a fade completion acts only if it is current.
    private var generation = 0

    init() {
        installTestHook()
    }

    /// Shows (or refreshes) the brightness OSD per the settings.
    /// When the mode is "the adjusted TV's screen" and that screen isn't paired/connected,
    /// nothing is shown — unless `allowFallback` (Preview / schedules) falls back to primary.
    func showBrightness(tvName: String?, value: Int, osd: OsdSettings, screenId: String?,
                        allowFallback: Bool = false) {
        guard let screen = resolveScreen(mode: osd.monitor, screenId: screenId,
                                         allowFallback: allowFallback) else { return }

        let showName = osd.showTvName && !(tvName ?? "").isEmpty
        let value = max(0, min(100, value))
        if osd.style == 0 {
            dismissPill()
            systemHud.show(.level(value: value, name: showName ? tvName : nil,
                                  showsValue: osd.showPercentage),
                           on: screen, timeout: osd.timeoutSeconds)
            return
        }

        systemHud.dismiss()
        model.mode = .brightness
        model.value = value
        model.showsValue = osd.showPercentage
        model.name = showName ? tvName : nil
        let size = NSSize(width: Self.winWidth, height: showName ? Self.winHeightWithName : Self.winHeight)
        showPill(on: screen, position: osd.position, size: size, timeout: osd.timeoutSeconds)
    }

    /// Shows the "no TV on this screen — link your TVs" prompt on the cursor's screen,
    /// WITHOUT changing any brightness.
    func showUnpaired(osd: OsdSettings) {
        showMessage(title: "No TV on this display",
                    subtitle: "Choose each TV's display on the Home page.",
                    symbol: "display.trianglebadge.exclamationmark", osd: osd)
    }

    /// Shown when the only TV's automation gate blocked a hotkey because its linked
    /// display isn't attached to this Mac.
    func showDisconnected(osd: OsdSettings) {
        showMessage(title: "TV isn't connected",
                    subtitle: "Its display isn't connected, so the shortcut leaves it alone.",
                    symbol: "cable.connector.slash", osd: osd)
    }

    private func showMessage(title: String, subtitle: String, symbol: String, osd: OsdSettings) {
        guard let screen = ScreenService.screenAtCursor() ?? NSScreen.main else { return }
        if osd.style == 0 {
            dismissPill()
            // Symbols that don't exist on this macOS fall back to a generic warning glyph.
            let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
                ? symbol : "exclamationmark.triangle.fill"
            systemHud.show(.message(title: title, subtitle: subtitle, symbol: glyph), on: screen,
                           timeout: osd.timeoutSeconds)
            return
        }

        systemHud.dismiss()
        model.mode = .message
        model.title = title
        model.subtitle = subtitle
        showPill(on: screen, position: osd.position,
                 size: NSSize(width: Self.msgWidth, height: Self.msgHeight), timeout: osd.timeoutSeconds)
    }

    // Resolves the screen to show the OSD on: 0 = primary, 1 = the adjusted TV's paired
    // screen, 2 = the screen under the cursor.
    private func resolveScreen(mode: Int, screenId: String?, allowFallback: Bool) -> NSScreen? {
        let primary = NSScreen.screens.first ?? NSScreen.main
        switch mode {
        case 2:
            return ScreenService.screenAtCursor() ?? primary
        case 1:
            if let paired = ScreenService.screen(withId: screenId) { return paired }
            // Only one display connected → it's unambiguously the one to use (not a fallback).
            if NSScreen.screens.count == 1 { return primary }
            return allowFallback ? primary : nil
        default:
            return primary
        }
    }

    /// The glyph the macOS-style level HUD draws (diagnostics compare with the speaker).
    var systemHudSymbol: String {
        get { systemHud.levelSymbol }
        set { systemHud.levelSymbol = newValue }
    }

    /// Diagnostics: ignore our menu bar item when placing the macOS-style HUD.
    var systemHudIgnoresMenuBarItem: Bool {
        get { systemHud.ignoresMenuBarItem }
        set { systemHud.ignoresMenuBarItem = newValue }
    }

    /// Diagnostics: whichever OSD is up shows its content (the old empty-pill invariant).
    var osdContentIsAttached: Bool {
        let pillOK = !visible || (panel?.isVisible == true && panel?.contentView is NSHostingView<OsdView>)
        return pillOK && systemHud.contentIsAttached
    }

    func close() {
        systemHud.close()
        hideTimer?.invalidate()
        hideTimer = nil
        generation += 1
        panel?.orderOut(nil)
        panel = nil
        visible = false
        hiding = false
    }

    // MARK: - Windows-style pill

    // Places the pill at one of six anchors on the screen's visible frame, then slides +
    // fades it in (or snaps it if already up).
    private func showPill(on screen: NSScreen, position: Int, size: NSSize, timeout: TimeInterval) {
        let panel = ensurePanel()

        let work = screen.visibleFrame
        let top = position == 3 || position == 4 || position == 5
        let x: CGFloat = switch position {
        case 1, 4: work.minX + Self.edgeMargin                       // left
        case 2, 5: work.maxX - size.width - Self.edgeMargin          // right
        default: work.midX - size.width / 2                          // centre (0, 3)
        }
        let y = top
            ? work.maxY - size.height - Self.edgeMargin
            : work.minY + Self.bottomMargin
        finalOrigin = NSPoint(x: x, y: y)
        anchoredTop = top

        let finalFrame = NSRect(origin: finalOrigin, size: size)

        if !visible {
            // Pre-place just off the resting spot (above for top anchors, below for bottom)
            // and fade up into place.
            generation += 1
            panel.alphaValue = 0
            panel.setFrame(finalFrame.offsetBy(dx: 0, dy: anchoredTop ? Self.slide : -Self.slide),
                           display: false)
            panel.orderFrontRegardless()
            visible = true
            hiding = false
            animate(to: finalFrame, alpha: 1, duration: Self.fadeIn, easeOut: true)
        } else if hiding {
            // Interrupted mid fade-out: glide back to fully visible from wherever we are.
            generation += 1
            hiding = false
            animate(to: finalFrame, alpha: 1, duration: Self.fadeIn, easeOut: true)
        } else {
            // Already up: snap to the (possibly new) anchor without re-running the entrance.
            panel.setFrame(finalFrame, display: true)
            panel.alphaValue = 1
        }

        hideTimer?.invalidate()
        hideTimer = Self.mainTimer(after: max(0.5, min(5.0, timeout))) { [weak self] in self?.beginHide() }
    }

    private func beginHide() {
        guard let panel, visible else { return }
        generation += 1
        let gen = generation
        hiding = true
        let exit = NSRect(origin: NSPoint(x: finalOrigin.x,
                                          y: finalOrigin.y + (anchoredTop ? Self.slide : -Self.slide)),
                          size: panel.frame.size)
        animate(to: exit, alpha: 0, duration: Self.fadeOut, easeOut: false) { [weak self] in
            // A re-show (or the other style taking over) since this fade began wins.
            guard let self, self.generation == gen, self.hiding else { return }
            self.panel?.orderOut(nil)
            self.visible = false
            self.hiding = false
        }
    }

    // Hides the pill at once, e.g. when the macOS style takes over.
    private func dismissPill() {
        guard visible else { return }
        hideTimer?.invalidate()
        hideTimer = nil
        generation += 1
        panel?.orderOut(nil)
        visible = false
        hiding = false
    }

    private func animate(to frame: NSRect, alpha: CGFloat, duration: TimeInterval,
                         easeOut: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: easeOut ? .easeOut : .easeIn)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = alpha
        }, completionHandler: {
            if let completion {
                Task { @MainActor in completion() }
            }
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.winWidth, height: Self.winHeight),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none // we drive the slide + fade ourselves

        let hosting = NSHostingView(rootView: OsdView(model: model))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    /// A one-shot timer on the main run loop, for hiding an OSD. It acts in the timer's own
    /// callback: hopping to a task first would let a show that arrives in between be hidden
    /// at once, since invalidating a timer that has already fired cancels nothing. And it
    /// runs in the common modes, so the OSD still goes while a slider is being dragged.
    static func mainTimer(after interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

// MARK: - Windows-style content

@MainActor
@Observable
final class OsdModel {
    enum Mode { case brightness, message }
    var mode: Mode = .brightness
    var value = 50
    var showsValue = true
    var name: String?
    var title = ""
    var subtitle = ""
}

/// The frosted Windows-style pill. Materials render as blur-behind-window because the
/// hosting panel is transparent.
struct OsdView: View {
    let model: OsdModel

    private let cornerRadius: CGFloat = 14

    var body: some View {
        Group {
            switch model.mode {
            case .brightness: winBrightness
            case .message: message
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        }
    }

    /// The TVControlForWin-style pill (icon + bar + numeric value).
    private var winBrightness: some View {
        VStack(spacing: 6) {
            if let name = model.name {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.primary)
                            .frame(width: geo.size.width * CGFloat(model.value) / 100)
                    }
                }
                .frame(height: 5)
                if model.showsValue {
                    Text("\(model.value)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(minWidth: 28, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.title).font(.system(size: 13, weight: .semibold))
            Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
}
