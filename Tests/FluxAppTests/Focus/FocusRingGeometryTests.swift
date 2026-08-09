// FluxAppTests.Focus — transient focus ring geometry (design spec §5).
//
// Deterministic, permission-free tests for the pure display-selection and
// coordinate conversion that maps an AX frame (Quartz space: top-left
// origin, y down) onto an AppKit screen frame (bottom-left origin, y up).
// Nothing here launches Flux, touches the window server, or prompts for
// Accessibility; every display descriptor is fabricated.

import Testing
import CoreGraphics
@testable import FluxApp

// MARK: - Fixtures

private func display(quartz: CGRect, appKit: CGRect) -> FocusRingDisplay {
    FocusRingDisplay(quartzBounds: quartz, appKitFrame: appKit)
}

private func primaryDisplay() -> FocusRingDisplay {
    display(
        quartz: CGRect(x: 0, y: 0, width: 1440, height: 900),
        appKit: CGRect(x: 0, y: 0, width: 1440, height: 900)
    )
}

private func rightDisplay() -> FocusRingDisplay {
    display(
        quartz: CGRect(x: 1440, y: 0, width: 1280, height: 800),
        appKit: CGRect(x: 1440, y: 0, width: 1280, height: 800)
    )
}

private func leftDisplay() -> FocusRingDisplay {
    display(
        quartz: CGRect(x: -1280, y: 0, width: 1280, height: 800),
        appKit: CGRect(x: -1280, y: 0, width: 1280, height: 800)
    )
}

private func aboveDisplay() -> FocusRingDisplay {
    display(
        quartz: CGRect(x: 0, y: -800, width: 1440, height: 800),
        appKit: CGRect(x: 0, y: 900, width: 1440, height: 800)
    )
}

private func belowDisplay() -> FocusRingDisplay {
    display(
        quartz: CGRect(x: 0, y: 900, width: 1440, height: 800),
        appKit: CGRect(x: 0, y: -800, width: 1440, height: 800)
    )
}

// MARK: - Display selection

struct FocusRingDisplaySelectionTests {
    @Test func picksPrimaryWhenTargetCenterIsInside() {
        let displays = [primaryDisplay(), rightDisplay()]
        let target = CGRect(x: 100, y: 200, width: 300, height: 80)
        #expect(FocusRingGeometry.display(forAXFrame: target, among: displays) == primaryDisplay())
    }

    @Test func picksRightDisplayWhenTargetCenterIsInside() {
        let displays = [primaryDisplay(), rightDisplay()]
        let target = CGRect(x: 1500, y: 100, width: 200, height: 50)
        #expect(FocusRingGeometry.display(forAXFrame: target, among: displays) == rightDisplay())
    }

    @Test func picksLeftDisplayWhenTargetCenterIsInside() {
        let displays = [primaryDisplay(), leftDisplay()]
        let target = CGRect(x: -1100, y: 100, width: 200, height: 50)
        #expect(FocusRingGeometry.display(forAXFrame: target, among: displays) == leftDisplay())
    }

    @Test func picksAboveDisplayWhenTargetCenterIsInside() {
        let displays = [primaryDisplay(), aboveDisplay()]
        let target = CGRect(x: 100, y: -600, width: 200, height: 100)
        #expect(FocusRingGeometry.display(forAXFrame: target, among: displays) == aboveDisplay())
    }

    @Test func picksBelowDisplayWhenTargetCenterIsInside() {
        let displays = [primaryDisplay(), belowDisplay()]
        let target = CGRect(x: 100, y: 1000, width: 200, height: 100)
        #expect(FocusRingGeometry.display(forAXFrame: target, among: displays) == belowDisplay())
    }

    @Test func containingCenterWinsOverLargerIntersectionCandidate() {
        // The target center lies inside B even though the frame straddles
        // the boundary; the containing display must win.
        let a = display(
            quartz: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            appKit: CGRect(x: 0, y: 0, width: 1000, height: 1000)
        )
        let b = display(
            quartz: CGRect(x: 1000, y: 0, width: 100, height: 100),
            appKit: CGRect(x: 1000, y: 0, width: 100, height: 100)
        )
        let target = CGRect(x: 1000, y: 40, width: 50, height: 20)
        #expect(FocusRingGeometry.display(forAXFrame: target, among: [a, b]) == b)
    }

    @Test func fallbackUsesBestIntersectionWithDeterministicTieBreak() {
        // Center (100, 100) sits on the shared corner of A and B, inside
        // neither; selection falls back to best intersection. Both displays
        // intersect the frame equally, so the geometric tie-break (Quartz
        // origin x) must pick A deterministically, independent of input
        // array order.
        let a = display(
            quartz: CGRect(x: 0, y: 0, width: 100, height: 100),
            appKit: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let b = display(
            quartz: CGRect(x: 100, y: 0, width: 100, height: 100),
            appKit: CGRect(x: 100, y: 0, width: 100, height: 100)
        )
        let target = CGRect(x: 50, y: 50, width: 100, height: 100)
        #expect(FocusRingGeometry.display(forAXFrame: target, among: [a, b]) == a)
        #expect(FocusRingGeometry.display(forAXFrame: target, among: [b, a]) == a)
    }

    @Test func fallbackFailsClosedWhenNoDisplayIntersects() {
        let a = display(
            quartz: CGRect(x: 0, y: 0, width: 100, height: 100),
            appKit: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let b = display(
            quartz: CGRect(x: 100, y: 0, width: 100, height: 100),
            appKit: CGRect(x: 100, y: 0, width: 100, height: 100)
        )
        // Below both displays: no intersection, no containing center.
        let target = CGRect(x: 50, y: 200, width: 100, height: 100)
        #expect(FocusRingGeometry.display(forAXFrame: target, among: [a, b]) == nil)
    }
}

// MARK: - Coordinate conversion

struct FocusRingConversionTests {
    @Test func primaryDisplayConversion() {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 80)
        #expect(
            FocusRingGeometry.appKitFrame(forAXFrame: frame, display: primaryDisplay())
                == CGRect(x: 100, y: 620, width: 300, height: 80)
        )
    }

    @Test func rightDisplayConversionUsesDisplayHeightNotPrimary() {
        // If the implementation wrongly flipped with the primary's 900pt
        // height, the top edge would land at y = 800 instead of 700.
        let frame = CGRect(x: 1500, y: 100, width: 200, height: 50)
        #expect(
            FocusRingGeometry.appKitFrame(forAXFrame: frame, display: rightDisplay())
                == CGRect(x: 1500, y: 650, width: 200, height: 50)
        )
    }

    @Test func leftDisplayConversion() {
        let frame = CGRect(x: -1100, y: 100, width: 200, height: 50)
        #expect(
            FocusRingGeometry.appKitFrame(forAXFrame: frame, display: leftDisplay())
                == CGRect(x: -1100, y: 650, width: 200, height: 50)
        )
    }

    @Test func aboveDisplayConversion() {
        let frame = CGRect(x: 100, y: -600, width: 200, height: 100)
        #expect(
            FocusRingGeometry.appKitFrame(forAXFrame: frame, display: aboveDisplay())
                == CGRect(x: 100, y: 1400, width: 200, height: 100)
        )
    }

    @Test func belowDisplayConversion() {
        let frame = CGRect(x: 100, y: 1000, width: 200, height: 100)
        #expect(
            FocusRingGeometry.appKitFrame(forAXFrame: frame, display: belowDisplay())
                == CGRect(x: 100, y: -200, width: 200, height: 100)
        )
    }
}

// MARK: - Panel frame padding

struct FocusRingPanelFrameTests {
    @Test func panelFrameExpandsByPaddingOnEverySide() {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 80)
        #expect(
            FocusRingGeometry.panelFrame(forAXFrame: frame, display: primaryDisplay(), padding: 6)
                == CGRect(x: 94, y: 614, width: 312, height: 92)
        )
    }

    @Test func zeroPaddingKeepsTheConvertedFrame() {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 80)
        #expect(
            FocusRingGeometry.panelFrame(forAXFrame: frame, display: primaryDisplay(), padding: 0)
                == CGRect(x: 100, y: 620, width: 300, height: 80)
        )
    }

    @Test func invalidPaddingFailsClosed() {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 80)
        #expect(
            FocusRingGeometry.panelFrame(
                forAXFrame: frame,
                display: primaryDisplay(),
                padding: -1
            ) == nil
        )
        #expect(
            FocusRingGeometry.panelFrame(
                forAXFrame: frame,
                display: primaryDisplay(),
                padding: .infinity
            ) == nil
        )
        #expect(
            FocusRingGeometry.panelFrame(
                forAXFrame: frame,
                display: primaryDisplay(),
                padding: .nan
            ) == nil
        )
    }
}

// MARK: - Invalid frames fail closed

struct FocusRingInvalidFrameTests {
    @Test func nonFiniteAXFrameFailsClosed() {
        let displays = [primaryDisplay()]
        #expect(
            FocusRingGeometry.display(
                forAXFrame: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                among: displays
            ) == nil
        )
        #expect(
            FocusRingGeometry.display(
                forAXFrame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
                among: displays
            ) == nil
        )
        #expect(
            FocusRingGeometry.appKitFrame(
                forAXFrame: CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan),
                display: primaryDisplay()
            ) == nil
        )
    }

    @Test func derivedBoundsOverflowFailsClosed() {
        let overflow = CGRect(
            x: CGFloat.greatestFiniteMagnitude,
            y: 0,
            width: CGFloat.greatestFiniteMagnitude,
            height: 100
        )
        #expect(
            FocusRingGeometry.display(forAXFrame: overflow, among: [primaryDisplay()]) == nil
        )
        #expect(
            FocusRingGeometry.appKitFrame(forAXFrame: overflow, display: primaryDisplay()) == nil
        )
    }

    @Test func nonPositiveAXFrameFailsClosed() {
        let displays = [primaryDisplay()]
        #expect(
            FocusRingGeometry.display(
                forAXFrame: CGRect(x: 0, y: 0, width: 0, height: 100),
                among: displays
            ) == nil
        )
        #expect(
            FocusRingGeometry.display(
                forAXFrame: CGRect(x: 0, y: 0, width: 100, height: -10),
                among: displays
            ) == nil
        )
        #expect(
            FocusRingGeometry.appKitFrame(
                forAXFrame: CGRect(x: 0, y: 0, width: -1, height: 100),
                display: primaryDisplay()
            ) == nil
        )
    }

    @Test func emptyDisplayListFailsClosed() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(FocusRingGeometry.display(forAXFrame: target, among: []) == nil)
    }

    @Test func invalidDisplayDescriptorsAreSkipped() {
        let invalid = display(
            quartz: CGRect(x: 0, y: CGFloat.nan, width: 100, height: 100),
            appKit: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let target = CGRect(x: 100, y: 200, width: 300, height: 80)
        #expect(FocusRingGeometry.display(forAXFrame: target, among: [invalid]) == nil)
        #expect(
            FocusRingGeometry.display(forAXFrame: target, among: [invalid, primaryDisplay()])
                == primaryDisplay()
        )
        #expect(
            FocusRingGeometry.appKitFrame(forAXFrame: target, display: invalid) == nil
        )
    }
}
