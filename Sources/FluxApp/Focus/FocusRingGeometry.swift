// FluxApp.Focus — focus ring display geometry.
//
// Pure, permission-free conversion between the two macOS global screen
// coordinate spaces used by the transient focus ring (design spec §5):
//
// - Quartz/Accessibility space: origin is the top-left corner of the main
//   display; the y axis increases downward. AXPosition/AXSize and
//   CGDisplayBounds live here.
// - AppKit space: origin is the bottom-left corner of the primary screen;
//   the y axis increases upward. NSScreen.frame lives here.
//
// An AX frame is converted with the display that contains its center,
// falling back to the display whose bounds best intersect the frame
// (deterministic tie-break). Each display maps its own Quartz bounds to its
// own AppKit frame, so conversion never assumes the main screen's height.
// Nothing here touches the window server or Accessibility, which keeps the
// selection rules unit-testable without permissions (design spec §7).

import CoreGraphics

/// One physical display described in both global coordinate spaces.
struct FocusRingDisplay: Equatable {
    /// The display bounds in Quartz space (`CGDisplayBounds`): top-left
    /// origin, y axis increasing downward.
    let quartzBounds: CGRect
    /// The display frame in AppKit space (`NSScreen.frame`): bottom-left
    /// origin, y axis increasing upward.
    let appKitFrame: CGRect

    init(quartzBounds: CGRect, appKitFrame: CGRect) {
        self.quartzBounds = quartzBounds
        self.appKitFrame = appKitFrame
    }
}

/// Pure geometry for the transient focus ring (design spec §5).
enum FocusRingGeometry {
    /// Selects the display used to convert `axFrame` into AppKit space.
    ///
    /// Displays whose Quartz bounds or AppKit frames are invalid are
    /// ignored. Displays that contain the AX frame's center win immediately
    /// (ties by largest intersection, then a deterministic geometric
    /// tie-break); when no display contains the center, the display whose
    /// bounds intersect the frame with the largest area wins, and the
    /// selection fails closed (nil) when the frame intersects nothing.
    static func display(
        forAXFrame axFrame: CGRect,
        among displays: [FocusRingDisplay]
    ) -> FocusRingDisplay? {
        guard axFrame.isFinitePositive else { return nil }
        let valid = displays.filter {
            $0.quartzBounds.isFinitePositive && $0.appKitFrame.isFinitePositive
        }
        guard !valid.isEmpty else { return nil }

        let center = CGPoint(x: axFrame.midX, y: axFrame.midY)
        let containing = valid.filter { $0.quartzBounds.contains(center) }
        let pool = containing.isEmpty ? valid : containing

        var best: FocusRingDisplay?
        var bestScore: DisplayScore?
        for (index, display) in pool.enumerated() {
            let score = DisplayScore(
                negativeIntersectionArea: -display.quartzBounds.intersectionArea(with: axFrame),
                quartzMinX: display.quartzBounds.minX,
                quartzMinY: display.quartzBounds.minY,
                quartzWidth: display.quartzBounds.width,
                quartzHeight: display.quartzBounds.height,
                appKitMinX: display.appKitFrame.minX,
                appKitMinY: display.appKitFrame.minY,
                index: index
            )
            if let current = bestScore {
                if score < current {
                    bestScore = score
                    best = display
                }
            } else {
                bestScore = score
                best = display
            }
        }
        guard let best else { return nil }
        if containing.isEmpty {
            // Fallback accepts only a display the frame actually overlaps;
            // otherwise fail closed without showing.
            guard best.quartzBounds.intersectionArea(with: axFrame) > 0 else { return nil }
        }
        return best
    }

    /// Converts an AX-space frame on `display` into the AppKit global frame.
    ///
    /// The AX frame's top-left corner maps through the display's own
    /// coordinate pair, with the AppKit y axis increasing upward:
    ///
    ///     appKitX = appKit.minX + (ax.minX - quartz.minX)
    ///     appKitY = (appKit.minY + appKit.height) - (ax.minY - quartz.minY)
    ///
    /// The returned frame is anchored at the resulting AppKit bottom-left
    /// corner (`appKitY` is the top edge, so the origin subtracts the
    /// height).
    static func appKitFrame(
        forAXFrame axFrame: CGRect,
        display: FocusRingDisplay
    ) -> CGRect? {
        guard axFrame.isFinitePositive,
              display.quartzBounds.isFinitePositive,
              display.appKitFrame.isFinitePositive else { return nil }
        let quartz = display.quartzBounds
        let appKit = display.appKitFrame
        let appKitTopY = (appKit.minY + appKit.height) - (axFrame.minY - quartz.minY)
        let appKitMinX = appKit.minX + (axFrame.minX - quartz.minX)
        let converted = CGRect(
            x: appKitMinX,
            y: appKitTopY - axFrame.height,
            width: axFrame.width,
            height: axFrame.height
        )
        return converted.isFinitePositive ? converted : nil
    }

    /// The ring panel's AppKit frame: the target frame expanded by
    /// `padding` on every side so the ring can be stroked outside it.
    static func panelFrame(
        forAXFrame axFrame: CGRect,
        display: FocusRingDisplay,
        padding: CGFloat
    ) -> CGRect? {
        guard padding.isFinite, padding >= 0,
              let appKit = appKitFrame(forAXFrame: axFrame, display: display) else {
            return nil
        }
        let panel = appKit.insetBy(dx: -padding, dy: -padding)
        return panel.isFinitePositive ? panel : nil
    }
}

/// Smaller is better: negative intersection area (larger overlap wins),
/// then Quartz origin and size, then AppKit origin, and finally the input
/// index so the result stays deterministic even for identical descriptors.
private struct DisplayScore: Comparable {
    var negativeIntersectionArea: CGFloat
    var quartzMinX: CGFloat
    var quartzMinY: CGFloat
    var quartzWidth: CGFloat
    var quartzHeight: CGFloat
    var appKitMinX: CGFloat
    var appKitMinY: CGFloat
    var index: Int

    static func < (lhs: DisplayScore, rhs: DisplayScore) -> Bool {
        if lhs.negativeIntersectionArea != rhs.negativeIntersectionArea {
            return lhs.negativeIntersectionArea < rhs.negativeIntersectionArea
        }
        if lhs.quartzMinX != rhs.quartzMinX { return lhs.quartzMinX < rhs.quartzMinX }
        if lhs.quartzMinY != rhs.quartzMinY { return lhs.quartzMinY < rhs.quartzMinY }
        if lhs.quartzWidth != rhs.quartzWidth { return lhs.quartzWidth < rhs.quartzWidth }
        if lhs.quartzHeight != rhs.quartzHeight { return lhs.quartzHeight < rhs.quartzHeight }
        if lhs.appKitMinX != rhs.appKitMinX { return lhs.appKitMinX < rhs.appKitMinX }
        if lhs.appKitMinY != rhs.appKitMinY { return lhs.appKitMinY < rhs.appKitMinY }
        return lhs.index < rhs.index
    }
}

extension CGRect {
    /// True when every component is finite and both width and height are
    /// strictly positive.
    var isFinitePositive: Bool {
        origin.x.isFinite && origin.y.isFinite
            && size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
            && minX.isFinite && maxX.isFinite
            && minY.isFinite && maxY.isFinite
            && midX.isFinite && midY.isFinite
    }

    /// The intersection area with `other`, or zero when they do not overlap.
    fileprivate func intersectionArea(with other: CGRect) -> CGFloat {
        let intersection = intersection(other)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}
