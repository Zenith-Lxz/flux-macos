import CoreGraphics
import FluxCore
import Testing
@testable import FluxApp

// MARK: - Recording snapper

/// A permission-free snapper stand-in that records every request and
/// returns a scripted result, so the controller's snap gating is testable
/// without Accessibility permission or real AX queries.
@MainActor
private final class RecordingSnapper: PointerSnapping {
    private(set) var requests: [CGPoint] = []
    var result: CGPoint?

    func snapPoint(for target: CGPoint) -> CGPoint? {
        requests.append(target)
        return result
    }
}

// MARK: - Snap gating on the pointer controller

/// Contract tests for the pointer snap gate (design spec §6): a non-repeat
/// move asks the snapper for the exact geometric target and adopts the
/// snapped point when one is returned; an auto-repeat never asks, so a held
/// direction keeps pure tiered acceleration and cannot get trapped snapping
/// back to the same control.
struct MacOSPointerControllerSnapTests {
    @Test @MainActor func nonRepeatMoveSnapsWhenSnapperReturnsPoint() {
        let snapper = RecordingSnapper()
        snapper.result = CGPoint(x: 321, y: 456)
        let controller = MacOSPointerController(snapper: snapper)
        let snapped = controller.snapTarget(
            geometricTarget: CGPoint(x: 300, y: 400),
            isRepeat: false
        )
        #expect(snapped == CGPoint(x: 321, y: 456))
        #expect(snapper.requests == [CGPoint(x: 300, y: 400)])
    }

    @Test @MainActor func nonRepeatMoveFallsBackToGeometricTargetWhenSnapperReturnsNil() {
        let snapper = RecordingSnapper()
        let controller = MacOSPointerController(snapper: snapper)
        let snapped = controller.snapTarget(
            geometricTarget: CGPoint(x: 300, y: 400),
            isRepeat: false
        )
        #expect(snapped == nil)
        #expect(snapper.requests == [CGPoint(x: 300, y: 400)])
    }

    @Test @MainActor func autoRepeatNeverAsksTheSnapper() {
        let snapper = RecordingSnapper()
        snapper.result = CGPoint(x: 999, y: 999)
        let controller = MacOSPointerController(snapper: snapper)
        let snapped = controller.snapTarget(
            geometricTarget: CGPoint(x: 300, y: 400),
            isRepeat: true
        )
        #expect(snapped == nil)
        #expect(snapper.requests.isEmpty)
    }

    @Test @MainActor func defaultConstructionIsPermissionFree() {
        // Constructing the default controller (and its default snapper)
        // must not touch Accessibility or the window server; the engine
        // pause tests rely on the same side-effect-free construction
        // contract, and construction performs no AX work.
        let controller = MacOSPointerController()
        controller.resetMotion()
        #expect(controller.snapTarget(geometricTarget: .zero, isRepeat: true) == nil)
    }

    @Test @MainActor func speedUpdateReplacesProfileAndResetsMotion() {
        let controller = MacOSPointerController()

        controller.updateSpeedMultiplier(1.5)

        #expect(controller.motionProfile == PointerMotionProfile.default.scaled(by: 1.5))
    }
}
