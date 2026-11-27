// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI

/// Flashes a badge in the centre of every connected display showing its name (and the
/// TV linked to it, if any), so pairing a TV to the right display is foolproof.
@MainActor
enum DisplayIdentifier {
    private static var panels: [NSPanel] = []
    private static var hideTimer: Timer?
    private static let fade: TimeInterval = 0.18

    static func flash(for seconds: TimeInterval = 2.2) {
        dismiss()

        for screen in NSScreen.screens {
            let id = ScreenService.stableId(for: screen)
            let linkedTv = id.flatMap { screenId in
                AppState.shared.tvs.first { $0.linkedScreenId == screenId }?.name
            }

            let hosting = NSHostingView(rootView: IdentifyBadge(name: screen.localizedName,
                                                                linkedTv: linkedTv))
            let size = hosting.fittingSize
            let frame = NSRect(x: screen.frame.midX - size.width / 2,
                               y: screen.frame.midY - size.height / 2,
                               width: size.width, height: size.height)

            let panel = NSPanel(contentRect: frame,
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
            panel.contentView = hosting

            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fade
                panel.animator().alphaValue = 1
            }
            panels.append(panel)
        }

        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in dismissAnimated() }
        }
    }

    private static func dismissAnimated() {
        let fading = panels
        panels = []
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fade
            for panel in fading { panel.animator().alphaValue = 0 }
        }, completionHandler: {
            Task { @MainActor in
                for panel in fading { panel.orderOut(nil) }
            }
        })
    }

    private static func dismiss() {
        hideTimer?.invalidate()
        hideTimer = nil
        for panel in panels { panel.orderOut(nil) }
        panels = []
    }
}

private struct IdentifyBadge: View {
    let name: String
    let linkedTv: String?

    var body: some View {
        VStack(spacing: 5) {
            Text(name)
                .font(.system(size: 26, weight: .bold))
            if let linkedTv {
                Label(linkedTv, systemImage: "tv")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("Not linked to a TV")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        }
    }
}
