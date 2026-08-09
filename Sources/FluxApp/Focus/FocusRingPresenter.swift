// FluxApp.Focus — transient focus ring presenter (design spec §5).
//
// Drives the focus ring lifecycle: after a successful AX focus move, shows
// one reusable non-activating panel around the target's AX frame for about
// 700 ms total, fading during the final ~150 ms. A later show replaces and
// restarts the running ring and its timer; the single panel is reused, so
// rings never accumulate. The panel is created lazily on the first show, so
// constructing controllers in permission-free tests has no window-server
// side effect.
//
// Privacy boundary (design spec §4, §8): the presenter receives only the
// target's geometric AX frame, converts it into AppKit screen geometry
// immediately, and never retains the raw AX frame or any element content.

import AppKit
import CoreGraphics

/// Drives the transient focus ring.
@MainActor
final class FocusRingPresenter {
    /// Total ring lifetime, including the fade-out (seconds).
    static let totalDuration: TimeInterval = 0.7

    /// Fade-out duration at the end of the lifetime (seconds).
    static let fadeDuration: TimeInterval = 0.15

    /// Distance from the target frame edge to the ring (points).
    static let ringPadding: CGFloat = 6

    /// Ring redraw cadence while the panel is live (seconds).
    private static let frameInterval: TimeInterval = 1.0 / 60.0

    /// The single reusable panel; created on first show (lazy).
    private var panel: FocusRingPanel?

    /// Repeating display timer. Only ever touched on the main thread;
    /// `nonisolated(unsafe)` lets the nonisolated `deinit` invalidate it.
    private nonisolated(unsafe) var displayTimer: Timer?

    /// Shows the ring around an AX-space frame, replacing any running ring.
    /// Invalid frames, unknown display geometry, or conversion failure fail
    /// closed without showing and without disturbing an existing ring.
    func show(axFrame: CGRect) {
        guard let displays = Self.currentDisplays(),
              let display = FocusRingGeometry.display(forAXFrame: axFrame, among: displays),
              let panelFrame = FocusRingGeometry.panelFrame(
                forAXFrame: axFrame, display: display, padding: Self.ringPadding)
        else { return }

        // Replace any running ring and timer first; the panel is reused.
        displayTimer?.invalidate()
        displayTimer = nil

        let panel = ensurePanel()
        panel.setFrame(panelFrame, display: true)
        panel.ringView.alphaValue = 1
        panel.orderFrontRegardless()

        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyStep(start: start)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    deinit {
        displayTimer?.invalidate()
    }

    private func ensurePanel() -> FocusRingPanel {
        if let panel { return panel }
        let panel = FocusRingPanel(frame: .zero)
        self.panel = panel
        return panel
    }

    /// Advances the ring lifecycle: full alpha until the fade window, then
    /// a linear fade, then hide the panel and stop the timer. The firing
    /// timer is always the current `displayTimer` (a replacement invalidates
    /// the previous one before a new one is scheduled), so the timer is
    /// stopped through the property instead of being passed across actor
    /// isolation.
    private func applyStep(start: TimeInterval) {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let fadeStart = Self.totalDuration - Self.fadeDuration
        if elapsed >= Self.totalDuration {
            displayTimer?.invalidate()
            displayTimer = nil
            panel?.orderOut(nil)
            return
        }
        let alpha: CGFloat
        if elapsed >= fadeStart {
            alpha = CGFloat(1 - (elapsed - fadeStart) / Self.fadeDuration)
        } else {
            alpha = 1
        }
        panel?.ringView.alphaValue = alpha
    }

    /// The real display descriptors: each NSScreen mapped to its Quartz
    /// CGDisplayBounds, sorted deterministically by Quartz origin. Called
    /// only when a ring is actually shown, never during tests.
    private static func currentDisplays() -> [FocusRingDisplay]? {
        let displays = NSScreen.screens.compactMap { screen -> FocusRingDisplay? in
            guard let idNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(idNumber.uint32Value)
            return FocusRingDisplay(
                quartzBounds: CGDisplayBounds(displayID),
                appKitFrame: screen.frame
            )
        }
        guard !displays.isEmpty else { return nil }
        return displays.sorted { lhs, rhs in
            if lhs.quartzBounds.minX != rhs.quartzBounds.minX {
                return lhs.quartzBounds.minX < rhs.quartzBounds.minX
            }
            if lhs.quartzBounds.minY != rhs.quartzBounds.minY {
                return lhs.quartzBounds.minY < rhs.quartzBounds.minY
            }
            return lhs.quartzBounds.width < rhs.quartzBounds.width
        }
    }
}
