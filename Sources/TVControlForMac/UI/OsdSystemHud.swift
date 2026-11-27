// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI
import Observation

// The macOS-style OSD: a replica of the system volume/brightness HUD that macOS 26/27 hangs
// below the menu bar. All metrics, colours and timings below were measured from the real
// HUD on macOS 27.3 (build 26C5047e) at 2x: window captures, screen captures over solid
// backgrounds, and 60 fps recordings of the entrance/exit.
//
// Why not the real thing: the system HUD is drawn by MenuBarAgent (ControlCenter's
// "SystemBannerSlider" content) and every way into it is gated by
// com.apple.private.menubar.* entitlements. The old private OSD.framework path
// (OSDManager → OSDUIHelper) still exists on 27 but only draws the pre-Tahoe 200×200
// square HUD at the bottom of the screen, so it is not used.

/// Measured geometry of the system HUD (points, macOS 27.3).
enum OsdSystemHudMetrics {
    /// Capsule size. The ends are Apple's continuous (squircle) curve rather than
    /// semicircles, which is also what NSGlassEffectView draws.
    static let size = NSSize(width: 308, height: 66)
    /// The capsule's top edge sits this far below the menu bar.
    static let gapBelowMenuBar: CGFloat = 10
    /// Fallback centre when our menu bar item isn't on the target screen: where the system
    /// volume HUD sat on the test Mac (centred under the Sound item), from the right edge.
    static let fallbackCentreFromRight: CGFloat = 195.5
    /// Keeps the capsule off the screen edge when centring under an item near it.
    static let minimumEdgeMargin: CGFloat = 8
    /// Glyph: SF Symbol at 21 pt regular matched the speaker glyph's pixels best. Its ink
    /// (23 × 18.5) spans 19.5–42 pt from the left and is centred vertically; the ink, not
    /// the symbol's layout box, is what the system centres.
    static let glyphPointSize: CGFloat = 21
    static let glyphCentreX: CGFloat = 30.75
    /// Level indicator: a 4 pt high track starting 62.5 pt in, the whole track rounded only
    /// at its outer ends. Each 1 pt gap sits at the start of every cell but the first, so
    /// the first segment is 1 pt wider than the rest, as in the system HUD.
    ///
    /// The one deliberate departure from the system HUD: it has 16 segments (its keys move
    /// in sixteenths), this has 10, one per 10 %, so the usual 10 % steps fill whole
    /// segments instead of stopping part-way through one. The track is 215 pt rather than
    /// the measured 214 so each cell is 21.5 pt and its edges land on whole pixels at 2x.
    static let trackX: CGFloat = 62.5
    static let trackWidth: CGFloat = 215
    static let trackHeight: CGFloat = 4
    static let segments = 10
    static let segmentGap: CGFloat = 1
    /// Unfilled segments are white at 25 % (196 over the 176 glass on a light desktop).
    static let emptyOpacity: Double = 0.25
    /// Right inset after the track (308 − 62.5 − 215).
    static let trackTrailingInset: CGFloat = 30.5

    // The percentage is this app's addition (the system HUD has no number). It takes the
    // trailing end of the row: the track gives up room for it and still ends on whole
    // pixels per segment (175 pt, 17.5 pt each), so the segments stay crisp.
    // 62.5 + 175 + 11 + 37 + 22.5 = 308.
    static let valueTrailingInset: CGFloat = 22.5
    static let valueWidth: CGFloat = 37
    static let valueGap: CGFloat = 11
    static let trackWidthWithValue: CGFloat = 175
}

/// Measured motion of the system HUD (macOS 27.3, 60 fps recordings).
enum OsdSystemHudMotion {
    /// It grows from 0.9 to full size, anchored at its top centre (the top edge never moves),
    /// following a critically damped spring (ω ≈ 13.3 rad/s, settled in ~0.45 s).
    static let startScale: CGFloat = 0.9
    static let springStiffness: CGFloat = 177   // ω²
    static let springDamping: CGFloat = 26.6    // 2ω (critical)
    /// The glass fades in over ~0.4 s, nearly linearly after a soft start. The content
    /// trails it by ~0.1 s (0.36 when the glass is at 0.55) with a long tail (0.97 at
    /// ~0.55 s). Bézier fits, checked frame by frame against the recordings.
    static let glassFadeIn: CFTimeInterval = 0.4
    static let glassFadeInCurve = CAMediaTimingFunction(controlPoints: 0.1, 0, 0.6, 0.8)
    static let contentDelay: CFTimeInterval = 0.085
    static let contentFadeIn: CFTimeInterval = 0.5
    static let contentFadeInCurve = CAMediaTimingFunction(controlPoints: 0, 1, 0.5, 0.9)
    /// Exit: the glass decays roughly exponentially (τ ≈ 60 ms, faint tail to ~0.35 s), the
    /// content slightly ahead of it, while it shrinks back to 0.9 easing out over ~0.35 s.
    /// The content's longer duration is what makes it land on the recorded frames.
    static let contentFadeOut: CFTimeInterval = 0.42
    static let contentFadeOutCurve = CAMediaTimingFunction(controlPoints: 0.3, 0.6, 0.2, 1)
    static let glassFadeOut: CFTimeInterval = 0.35
    static let glassFadeOutCurve = CAMediaTimingFunction(controlPoints: 0.3, 0.6, 0.2, 1)
    static let shrink: CFTimeInterval = 0.35
    /// The rim leads the glass in (+12 levels at 0.1 s, full by ~0.25 s) and on the way out
    /// holds for a moment before following it.
    static let rimDelay: CFTimeInterval = 0.02
    static let rimFadeIn: CFTimeInterval = 0.2
    static let rimHold: CFTimeInterval = 0.03
    /// A new value while it's up animates the fill in ~0.12 s; there is no re-entrance.
    static let fillChange: Double = 0.12
}

// MARK: - Model

@MainActor
@Observable
final class OsdSystemHudModel {
    enum Content: Equatable {
        case level(value: Int, name: String?, showsValue: Bool)
        case message(title: String, subtitle: String, symbol: String)
    }
    var content: Content = .level(value: 50, name: nil, showsValue: false)
    /// The glyph drawn for the level HUD. Diagnostics can swap in the speaker to compare
    /// pixel-for-pixel against the system volume HUD.
    var levelSymbol = "sun.max.fill"
}

// MARK: - Panel

@MainActor
final class OsdSystemHud {
    private var panel: NSPanel?
    private var container: NSView?        // the scaled capsule
    private var glassGroup: NSView?       // fades the glass
    private var glass: NSView?            // NSGlassEffectView, or NSVisualEffectView before 26
    private var rim: OsdHudRimView?
    private var hosting: NSHostingView<OsdSystemHudView>?
    private let model = OsdSystemHudModel()
    private var hideTimer: Timer?

    private enum Phase { case hidden, entering, shown, exiting }
    private var phase = Phase.hidden
    // Bumped on every show and hide; an animation completion acts only if no newer
    // transition started after it was scheduled.
    private var generation = 0

    /// Outer margin around the capsule inside the panel, for the glass's edge ring.
    private static let margin: CGFloat = 2
    private static let glassRingInset: CGFloat = 0.5

    /// Diagnostics: place the HUD where the system volume HUD sits, even when our menu bar
    /// item is on screen, so both can be captured over the same background.
    var ignoresMenuBarItem = false

    var levelSymbol: String {
        get { model.levelSymbol }
        set { model.levelSymbol = newValue }
    }

    /// Diagnostics: whether the HUD, if it is up, really shows its content. This is the
    /// invariant the old OSD broke: a visible capsule whose content view had been detached.
    var contentIsAttached: Bool {
        guard phase != .hidden else { return true }
        guard let panel, let hosting, let container else { return false }
        return panel.isVisible && hosting.window === panel && hosting.superview === container
            && !hosting.isHidden && hosting.frame.size == container.bounds.size
    }

    func show(_ content: OsdSystemHudModel.Content, on screen: NSScreen, timeout: TimeInterval) {
        let size = Self.capsuleSize(for: content)
        let capsule = Self.capsuleFrame(size: size, on: screen, useMenuBarItem: !ignoresMenuBarItem)
        let panel = ensurePanel()
        layout(capsule: capsule)

        switch phase {
        case .hidden:
            setContent(content, animated: false)
            panel.orderFrontRegardless()
            runEntrance(fromScale: OsdSystemHudMotion.startScale, glassOpacity: 0, contentOpacity: 0)
        case .entering, .shown:
            // Already up: the system HUD just updates (animating the fill) and stays.
            setContent(content, animated: true)
        case .exiting:
            // Caught mid-exit: grow back from wherever the exit had got to.
            setContent(content, animated: true)
            let scale = container?.layer?.presentation()?.transform.m11 ?? OsdSystemHudMotion.startScale
            let glassOpacity = CGFloat(glassGroup?.layer?.presentation()?.opacity ?? 0)
            let contentOpacity = CGFloat(hosting?.layer?.presentation()?.opacity ?? 0)
            runEntrance(fromScale: scale, glassOpacity: glassOpacity, contentOpacity: contentOpacity)
        }

        hideTimer?.invalidate()
        hideTimer = OsdController.mainTimer(after: max(0.5, min(5.0, timeout))) { [weak self] in self?.runExit() }
    }

    /// Hides at once (no exit animation), e.g. when the other OSD style takes over.
    func dismiss() {
        hideTimer?.invalidate()
        hideTimer = nil
        generation += 1
        phase = .hidden
        removeAnimations()
        panel?.orderOut(nil)
    }

    func close() {
        dismiss()
        panel?.close()
        panel = nil
        container = nil
        glassGroup = nil
        glass = nil
        rim = nil
        hosting = nil
    }

    // MARK: Content

    private func setContent(_ content: OsdSystemHudModel.Content, animated: Bool) {
        guard content != model.content else { return }
        // Only a level → level change animates (the fill sliding); anything else swaps.
        if animated, case .level = content, case .level = model.content {
            withAnimation(.easeOut(duration: OsdSystemHudMotion.fillChange)) { model.content = content }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.content = content }
        }
    }

    private static func capsuleSize(for content: OsdSystemHudModel.Content) -> NSSize {
        let base = OsdSystemHudMetrics.size
        guard case .message(let title, let subtitle, _) = content else { return base }
        // Messages keep the HUD's height and insets and only grow wider for longer text.
        let titleWidth = (title as NSString).size(withAttributes: [.font: OsdSystemHudView.titleFont]).width
        let subtitleWidth = (subtitle as NSString).size(withAttributes: [.font: OsdSystemHudView.subtitleFont]).width
        let needed = OsdSystemHudMetrics.trackX + ceil(max(titleWidth, subtitleWidth))
            + OsdSystemHudMetrics.trackTrailingInset
        return NSSize(width: max(base.width, needed), height: base.height)
    }

    // MARK: Placement

    // Hangs the capsule 10 pt below the menu bar of `screen`, centred under our menu bar
    // item when it is shown on that screen (macOS 26+ hangs each HUD from the menu bar item
    // that owns it: volume under Sound), otherwise at the system volume HUD's spot.
    static func capsuleFrame(size: NSSize, on screen: NSScreen, useMenuBarItem: Bool = true) -> NSRect {
        let frame = screen.frame
        let menuBarBottom: CGFloat
        if screen.visibleFrame.maxY < frame.maxY - 0.5 {
            menuBarBottom = screen.visibleFrame.maxY
        } else {
            // Auto-hidden menu bar, or a display without one: sit where the bar would end
            // (30 pt is the 27.3 menu bar on a display without a notch; a notch is taller).
            menuBarBottom = frame.maxY - max(30, screen.safeAreaInsets.top)
        }
        let centreX = (useMenuBarItem ? statusItemMidX(on: screen) : nil)
            ?? frame.maxX - OsdSystemHudMetrics.fallbackCentreFromRight
        let margin = OsdSystemHudMetrics.minimumEdgeMargin
        var x = centreX - size.width / 2
        x = min(max(x, frame.minX + margin), frame.maxX - margin - size.width)
        let top = menuBarBottom - OsdSystemHudMetrics.gapBelowMenuBar
        let scale = screen.backingScaleFactor
        return NSRect(x: (x * scale).rounded() / scale, y: ((top - size.height) * scale).rounded() / scale,
                      width: size.width, height: size.height)
    }

    // Our MenuBarExtra item, if it is laid out in `screen`'s menu bar. On 27 an item has a
    // window per display; ones the bar couldn't fit (e.g. behind a notch) are parked at the
    // screen's left edge, so those don't count.
    private static func statusItemMidX(on screen: NSScreen) -> CGFloat? {
        let bar = screen.frame
        for window in NSApp.windows where window.className == "NSStatusBarWindow" && window.isVisible {
            let f = window.frame
            guard f.width > 1, f.height > 1,
                  abs(f.maxY - bar.maxY) < 1, f.minX > bar.minX + 1, f.maxX <= bar.maxX + 0.5 else { continue }
            return f.midX
        }
        return nil
    }

    // MARK: Views

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let size = OsdSystemHudMetrics.size
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size).insetBy(dx: -Self.margin, dy: -Self.margin),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false        // the system HUD casts no visible shadow
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // The measured HUD tone is exactly clear Liquid Glass in the dark appearance, in
        // light and dark mode alike (white content always), so the panel is forced dark.
        panel.appearance = NSAppearance(named: .darkAqua)

        let root = NSView(frame: panel.contentLayoutRect)
        root.wantsLayer = true
        panel.contentView = root

        // One fixed hierarchy, built once and never re-parented:
        //   container (scales) → glassGroup (glass), rim, hosting — each fading on its own
        // Re-parenting a hosting view in and out of the glass is what left the old OSD
        // empty. Content and rim are siblings above the glass, not inside it, because the
        // system HUD fades glass, rim and content on different curves (and the glass would
        // clip the rim's edge pixels).
        let container = NSView()
        container.wantsLayer = true
        root.addSubview(container)
        let glassGroup = NSView()
        glassGroup.wantsLayer = true
        container.addSubview(glassGroup)

        let glass: NSView
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.style = .clear
            glass = effect
        } else {
            // Before Tahoe the system HUD was a different (square, vibrant) design; keep a
            // dark HUD material capsule so the look stays coherent there.
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            glass = effect
        }
        glassGroup.addSubview(glass)
        let rim = OsdHudRimView()
        container.addSubview(rim)          // above the glass, fading on its own curve

        let hosting = NSHostingView(rootView: OsdSystemHudView(model: model))
        hosting.wantsLayer = true
        container.addSubview(hosting)

        self.panel = panel
        self.container = container
        self.glassGroup = glassGroup
        self.glass = glass
        self.rim = rim
        self.hosting = hosting
        return panel
    }

    private func layout(capsule: NSRect) {
        guard let panel, let container, let glassGroup, let glass, let hosting, let rim else { return }
        let m = Self.margin
        // The window server keeps window origins on whole points, while the measured HUD
        // sits on half points; carry the fraction inside the panel instead.
        let outer = capsule.insetBy(dx: -m, dy: -m)
        let origin = NSPoint(x: outer.minX.rounded(.down), y: outer.minY.rounded(.down))
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: ceil(outer.maxX) - origin.x,
                                                           height: ceil(outer.maxY) - origin.y)), display: false)
        let local = NSRect(x: capsule.minX - origin.x, y: capsule.minY - origin.y,
                           width: capsule.width, height: capsule.height)
        guard container.frame != local else { return }
        container.frame = local
        let bounds = container.bounds
        glassGroup.frame = bounds
        hosting.frame = bounds
        rim.frame = bounds
        let radius = capsule.height / 2
        if #available(macOS 26.0, *), let effect = glass as? NSGlassEffectView {
            // Liquid Glass draws a dark edge ring about half a point outside its frame;
            // inset it so that ring lands on the capsule's outermost device pixel, where
            // the system HUD has its dark edge.
            effect.frame = bounds.insetBy(dx: Self.glassRingInset, dy: Self.glassRingInset)
            effect.cornerRadius = radius - Self.glassRingInset
        } else {
            glass.frame = bounds
            glass.layer?.cornerRadius = radius
        }
        rim.needsLayout = true
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: Animation

    // Scale about the capsule's top centre (the system HUD's top edge never moves). A
    // view-backed layer's anchor is its bottom-left corner, hence the translation.
    private func topAnchoredScale(_ s: CGFloat) -> CATransform3D {
        guard let bounds = container?.bounds else { return CATransform3DIdentity }
        var t = CATransform3DMakeScale(s, s, 1)
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(bounds.width / 2 * (1 - s), bounds.height * (1 - s), 0))
        return t
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private struct AnimatedLayers {
        let scale: CALayer, glass: CALayer, rim: CALayer, content: CALayer
        var all: [CALayer] { [scale, glass, rim, content] }
    }

    private var animatedLayers: AnimatedLayers? {
        guard let scale = container?.layer, let glass = glassGroup?.layer, let rim = rim?.layer,
              let content = hosting?.layer else { return nil }
        return AnimatedLayers(scale: scale, glass: glass, rim: rim, content: content)
    }

    private func removeAnimations() {
        animatedLayers?.all.forEach { $0.removeAllAnimations() }
    }

    private func fade(_ layer: CALayer, from: Float, to: Float, delay: CFTimeInterval = 0,
                      duration: CFTimeInterval, curve: CAMediaTimingFunction, hold: Bool) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.beginTime = CACurrentMediaTime() + delay
        fade.duration = duration
        fade.timingFunction = curve
        fade.fillMode = hold ? .both : .backwards
        fade.isRemovedOnCompletion = !hold
        layer.add(fade, forKey: "fade")
    }

    private func runEntrance(fromScale: CGFloat, glassOpacity: CGFloat, contentOpacity: CGFloat) {
        guard let layers = animatedLayers else { return }
        generation += 1
        phase = .entering
        let gen = generation
        let resuming = glassOpacity > 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeAnimations()
        layers.scale.transform = CATransform3DIdentity
        layers.glass.opacity = 1
        layers.rim.opacity = 1
        layers.content.opacity = 1

        if !reduceMotion && fromScale < 0.999 {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 1
            spring.stiffness = OsdSystemHudMotion.springStiffness
            spring.damping = OsdSystemHudMotion.springDamping
            spring.fromValue = NSValue(caTransform3D: topAnchoredScale(fromScale))
            spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            spring.duration = spring.settlingDuration
            layers.scale.add(spring, forKey: "scale")
        }
        let remaining = Double(1 - glassOpacity)
        fade(layers.glass, from: Float(glassOpacity), to: 1, duration: OsdSystemHudMotion.glassFadeIn * remaining,
             curve: OsdSystemHudMotion.glassFadeInCurve, hold: false)
        fade(layers.rim, from: Float(glassOpacity), to: 1, delay: resuming ? 0 : OsdSystemHudMotion.rimDelay,
             duration: OsdSystemHudMotion.rimFadeIn * remaining, curve: CAMediaTimingFunction(name: .easeInEaseOut),
             hold: false)
        fade(layers.content, from: Float(contentOpacity), to: 1,
             delay: contentOpacity > 0 ? 0 : OsdSystemHudMotion.contentDelay,
             duration: OsdSystemHudMotion.contentFadeIn * Double(1 - contentOpacity),
             curve: OsdSystemHudMotion.contentFadeInCurve, hold: false)
        CATransaction.commit()

        let settle = max(OsdSystemHudMotion.glassFadeIn, OsdSystemHudMotion.contentDelay + OsdSystemHudMotion.contentFadeIn)
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self, self.generation == gen, self.phase == .entering else { return }
            self.phase = .shown
        }
    }

    private func runExit() {
        guard phase == .entering || phase == .shown, let layers = animatedLayers else { return }
        generation += 1
        phase = .exiting
        let gen = generation

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Start from what is on screen (an entrance may still be settling).
        let fromTransform = layers.scale.presentation()?.transform ?? CATransform3DIdentity
        let fromGlass = layers.glass.presentation()?.opacity ?? 1
        let fromRim = layers.rim.presentation()?.opacity ?? 1
        let fromContent = layers.content.presentation()?.opacity ?? 1
        removeAnimations()

        if !reduceMotion {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: fromTransform)
            shrink.toValue = NSValue(caTransform3D: topAnchoredScale(OsdSystemHudMotion.startScale))
            shrink.duration = OsdSystemHudMotion.shrink
            shrink.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layers.scale.add(shrink, forKey: "scale")
        }
        fade(layers.glass, from: fromGlass, to: 0, duration: OsdSystemHudMotion.glassFadeOut,
             curve: OsdSystemHudMotion.glassFadeOutCurve, hold: true)
        fade(layers.rim, from: fromRim, to: 0, delay: OsdSystemHudMotion.rimHold,
             duration: OsdSystemHudMotion.glassFadeOut, curve: OsdSystemHudMotion.glassFadeOutCurve, hold: true)
        fade(layers.content, from: fromContent, to: 0, duration: OsdSystemHudMotion.contentFadeOut,
             curve: OsdSystemHudMotion.contentFadeOutCurve, hold: true)
        CATransaction.commit()

        let done = max(OsdSystemHudMotion.shrink, OsdSystemHudMotion.rimHold + OsdSystemHudMotion.glassFadeOut,
                       OsdSystemHudMotion.contentFadeOut)
        DispatchQueue.main.asyncAfter(deadline: .now() + done) { [weak self] in
            guard let self, self.generation == gen, self.phase == .exiting else { return }
            self.phase = .hidden
            self.panel?.orderOut(nil)
            self.removeAnimations()
        }
    }
}

// MARK: - Content view

/// Glyph, level segments (or message text) laid out to the system HUD's measured metrics.
struct OsdSystemHudView: View {
    let model: OsdSystemHudModel

    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let subtitleFont = NSFont.systemFont(ofSize: 11, weight: .regular)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                glyph
                    .position(x: OsdSystemHudMetrics.glyphCentreX, y: geo.size.height / 2)
                let width = geo.size.width - OsdSystemHudMetrics.trackX - trailingInset
                trailing
                    .frame(width: width, alignment: .leading)
                    .position(x: OsdSystemHudMetrics.trackX + width / 2, y: geo.size.height / 2)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    // With the percentage shown, the row runs closer to the capsule's end.
    private var trailingInset: CGFloat {
        if case .level(_, _, true) = model.content { return OsdSystemHudMetrics.valueTrailingInset }
        return OsdSystemHudMetrics.trackTrailingInset
    }

    private var symbolName: String {
        switch model.content {
        case .level: model.levelSymbol
        case .message(_, _, let symbol): symbol
        }
    }

    private var glyph: some View {
        let ink = OsdSymbolInk.centreOffset(symbolName, pointSize: OsdSystemHudMetrics.glyphPointSize)
        return Image(systemName: symbolName)
            .font(.system(size: OsdSystemHudMetrics.glyphPointSize, weight: .regular))
            .fixedSize()
            .offset(x: -ink.width, y: -ink.height)
    }

    @ViewBuilder private var trailing: some View {
        switch model.content {
        case .level(let value, let name, let showsValue):
            let level = max(0, min(100, value))
            let trackWidth = showsValue ? OsdSystemHudMetrics.trackWidthWithValue : OsdSystemHudMetrics.trackWidth
            HStack(spacing: OsdSystemHudMetrics.valueGap) {
                // A name, when shown, is a caption above the track; the glyph and the track
                // keep their positions relative to each other and the HUD keeps its size.
                VStack(alignment: .leading, spacing: 6) {
                    if let name {
                        Text(name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    OsdLevelIndicator(level: Double(level) / 100)
                        .frame(width: trackWidth, height: OsdSystemHudMetrics.trackHeight)
                }
                .frame(width: trackWidth, alignment: .leading)
                // Without a name the track sits exactly on the centre line; with one, the pair
                // is centred as a block, nudged up 1 pt for the caption's unused descender space.
                .offset(y: name == nil ? 0 : -1)

                if showsValue {
                    // Centred on the capsule's own centre line whether or not there's a name.
                    Text("\(level)%")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: OsdSystemHudMetrics.valueWidth, alignment: .trailing)
                }
            }
        case .message(let title, let subtitle, _):
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Font(Self.titleFont))
                Text(subtitle).font(Font(Self.subtitleFont)).foregroundStyle(.white.opacity(0.7))
            }
            .lineLimit(1)
            .fixedSize()
        }
    }
}

/// Where a symbol's ink sits relative to the centre of its layout box (points, y down),
/// measured once per symbol by rasterising it, so glyphs can be centred by their ink.
@MainActor
enum OsdSymbolInk {
    private static var cache: [String: CGSize] = [:]

    static func centreOffset(_ name: String, pointSize: CGFloat) -> CGSize {
        let key = "\(name)@\(pointSize)"
        if let hit = cache[key] { return hit }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return .zero }
        let scale: CGFloat = 4
        let width = Int(ceil(image.size.width * scale)), height = Int(ceil(image.size.height * scale))
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return .zero }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        // Bitmap rows run top-down, like SwiftUI's y.
        let offset = CGSize(width: (CGFloat(minX + maxX + 1) / 2 - CGFloat(width) / 2) / scale,
                            height: (CGFloat(minY + maxY + 1) / 2 - CGFloat(height) / 2) / scale)
        cache[key] = offset
        return offset
    }
}

/// The segmented level indicator ("chiclets"): one segment per 10 %, partially filling the
/// segment the level ends in when it isn't a multiple of 10.
struct OsdLevelIndicator: View {
    var level: Double

    var body: some View {
        ZStack {
            OsdSegments(level: 1).fill(.white.opacity(OsdSystemHudMetrics.emptyOpacity))
            OsdSegments(level: level).fill(.white)
        }
        .clipShape(Capsule())
    }
}

/// Segment rectangles across the track, each cut at `level` (0…1 of the whole track).
struct OsdSegments: Shape {
    var level: Double

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let count = OsdSystemHudMetrics.segments
        let cell = rect.width / CGFloat(count)
        let gap = OsdSystemHudMetrics.segmentGap
        let filledCells = level * Double(count)
        var path = Path()
        for k in 0..<count {
            let fraction = CGFloat(max(0, min(1, filledCells - Double(k))))
            guard fraction > 0 else { break }
            let start = rect.minX + cell * CGFloat(k) + (k == 0 ? 0 : gap)
            let end = rect.minX + cell * CGFloat(k + 1)
            path.addRect(CGRect(x: start, y: rect.minY, width: (end - start) * fraction, height: rect.height))
        }
        return path
    }
}

// MARK: - Rim

/// The glass edge the system HUD has and plain clear glass lacks here: an additive white
/// specular rim strongest along the top and bottom that thins out round the ends, a dark
/// hairline on the ends, and a soft glow just under the top and bottom rims. Values were
/// fitted to captures of the 27.3 HUD over its light desktop and over solid backgrounds.
final class OsdHudRimView: NSView {
    private struct Band {
        let inset: CGFloat     // from the capsule edge (each band is one device pixel, 0.5 pt)
        let alpha: CGFloat     // added white on the straight top and bottom
        let falloff: CGFloat   // strength round the ends ∝ |sin θ|^falloff
    }

    // On the light desktop the system's top rim reads 255, 245, 200, 194 over ~184 glass.
    // Round the ends its outermost pixel fades early (by ~45°) while the next ones stay
    // lit further round, so each band gets its own falloff (fitted at 15° steps).
    private static let bands = [
        Band(inset: 0.25, alpha: 0.44, falloff: 4),     // 123 over black (glass 32)
        Band(inset: 0.75, alpha: 0.24, falloff: 1.6),
        Band(inset: 1.25, alpha: 0.07, falloff: 1),
        Band(inset: 1.75, alpha: 0.035, falloff: 1),
    ]
    // The ends' outermost device pixel: the glass's own edge ring does most of the
    // darkening (desktop 211 → 107, system 92; white 255 → 138, system 122) and this tops
    // it up. It fades out by ~30° round the curve, where the rim takes over.
    private static let hairlineAlpha: CGFloat = 0.12
    private static let hairlineReach: CGFloat = 0.5   // in |sin θ|
    // The glow under the rims: about +10 → 0 levels over the first ~6 pt inside.
    private static let glowAlpha: CGFloat = 0.05
    private static let glowDepth: CGFloat = 6
    // Clear glass in the dark appearance matches the system tone over light backgrounds
    // (177 vs 177 on the desktop) but sits 6–7 levels low over dark ones (25 vs 32 over
    // black, 48 vs 54 over dark grey); a faint light veil lifts the darks without moving
    // the lights.
    private static let lift = NSColor(white: 200.0 / 255, alpha: 0.04)

    private let liftLayer = CAShapeLayer()
    private var bandLayers: [(stroke: CAShapeLayer, mask: CAGradientLayer)] = []
    private let hairline = CAShapeLayer()
    private let hairlineMask = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let glowMask = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }
        layer.masksToBounds = false

        liftLayer.fillColor = Self.lift.cgColor
        layer.addSublayer(liftLayer)

        for band in Self.bands {
            let stroke = CAShapeLayer()
            stroke.fillColor = nil
            stroke.strokeColor = NSColor(white: 1, alpha: band.alpha).cgColor
            stroke.lineWidth = 0.5
            stroke.compositingFilter = "plusL"
            let mask = CAGradientLayer()
            stroke.mask = mask
            layer.addSublayer(stroke)
            bandLayers.append((stroke, mask))
        }

        hairline.fillColor = nil
        hairline.strokeColor = NSColor(white: 0, alpha: Self.hairlineAlpha).cgColor
        hairline.lineWidth = 0.5
        hairline.mask = hairlineMask
        layer.addSublayer(hairline)

        glow.colors = [NSColor(white: 1, alpha: Self.glowAlpha).cgColor, NSColor(white: 1, alpha: 0).cgColor,
                       NSColor(white: 1, alpha: 0).cgColor, NSColor(white: 1, alpha: Self.glowAlpha).cgColor]
        glow.compositingFilter = "plusL"
        glow.mask = glowMask
        layer.addSublayer(glow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        // The glass's own outline is Apple's continuous-corner capsule, not a semicircle
        // (measured against the system HUD's window mask), so the rim follows that shape.
        func capsule(inset: CGFloat) -> CGPath {
            Capsule(style: .continuous).path(in: b.insetBy(dx: inset, dy: inset)).cgPath
        }
        liftLayer.frame = b
        liftLayer.path = capsule(inset: 0.5)   // the glass itself, inside its edge ring

        // An angular profile as a vertical gradient: on the ends y tracks sin θ, and the
        // straight top and bottom are at |sin θ| = 1.
        func profile(_ strength: (CGFloat) -> CGFloat, into mask: CAGradientLayer) {
            let steps = 32
            var colors: [CGColor] = [], locations: [NSNumber] = []
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                colors.append(NSColor(white: 0, alpha: max(0, min(1, strength(abs(2 * t - 1))))).cgColor)
                locations.append(NSNumber(value: Double(t)))
            }
            mask.frame = b
            mask.colors = colors
            mask.locations = locations
            mask.startPoint = CGPoint(x: 0.5, y: 0)
            mask.endPoint = CGPoint(x: 0.5, y: 1)
        }

        for (band, layers) in zip(Self.bands, bandLayers) {
            layers.stroke.frame = b
            layers.stroke.path = capsule(inset: band.inset)
            profile({ pow($0, band.falloff) }, into: layers.mask)
        }

        hairline.frame = b
        hairline.path = capsule(inset: 0.25)
        profile({ 1 - $0 / Self.hairlineReach }, into: hairlineMask)

        glow.frame = b
        let depth = min(0.5, Self.glowDepth / max(1, b.height))
        glow.locations = [0, NSNumber(value: Double(depth)), NSNumber(value: Double(1 - depth)), 1]
        glowMask.frame = b
        glowMask.path = capsule(inset: 0)
        CATransaction.commit()
    }
}
