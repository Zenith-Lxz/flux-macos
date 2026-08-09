import CoreGraphics
import FluxCore
import Testing
@testable import FluxApp

@MainActor
private final class RecordingEventPoster: EventPosting {
    private(set) var events: [CGEvent] = []

    func post(_ event: CGEvent) {
        events.append(event)
    }
}

@MainActor
private final class NilSnapper: PointerSnapping {
    func snapPoint(for target: CGPoint) -> CGPoint? { nil }
}

struct PlatformBoundaryTests {
    @Test @MainActor func concretePlatformAdaptersConformToApprovedProtocols() {
        let _: any EventTapProviding = MacOSEventTapProvider()
        let _: any AXTreeReading = MacOSFocusController()
        let _: any FrontmostAppProviding = MacOSContextRuntime()
        let _: any EventPosting = MacOSEventPoster()
    }

    @Test @MainActor func pointerClickUsesInjectedEventPoster() {
        let poster = RecordingEventPoster()
        let controller = MacOSPointerController(
            snapper: NilSnapper(),
            eventPoster: poster
        )

        #expect(controller.click(.single))
        #expect(poster.events.count == 2)
        #expect(poster.events.allSatisfy {
            $0.getIntegerValueField(.eventSourceUserData) == SyntheticEventMarker.value
        })
    }

    @Test @MainActor func pointerMoveUsesInjectedEventPoster() {
        let poster = RecordingEventPoster()
        let controller = MacOSPointerController(
            snapper: NilSnapper(),
            eventPoster: poster
        )

        #expect(controller.move(
            direction: .right,
            fast: false,
            isRepeat: true,
            timestamp: 1
        ))
        #expect(poster.events.count == 1)
        #expect(poster.events[0].getIntegerValueField(
            .eventSourceUserData
        ) == SyntheticEventMarker.value)
    }
}
