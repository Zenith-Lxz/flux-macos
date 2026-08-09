// FluxApp.Pointer — macOS concrete pointer controller.
//
// Bridges one FluxCore pointer action (design spec §6: Caps + Option +
// direction keys move the pointer, Caps + Option + Return clicks) into real
// CoreGraphics events. The controller owns the platform-neutral
// PointerMotionState so tiered acceleration stays in FluxCore
// (unit-testable without permissions); this type only reads the cursor,
// maps logical coordinates onto Quartz's +Y-down screen space, and posts
// synthetic events.
//
// Synthetic-event contract (design spec §7, AGENTS.md): every posted event
// carries the private eventSourceUserData marker so the event tap can
// recognize Flux output and pass it through instead of reprocessing it.
// The controller requests no permissions and presents no UI; posting
// relies on the host's existing Accessibility/Input Monitoring trust and
// fails closed by returning false when an event cannot be created.

import CoreGraphics
import FluxCore
import Foundation

/// Moves the system pointer or posts primary-button clicks.
///
/// All event posting targets `.cghidEventTap` so the system emits the
/// hardware-level event; the cursor is never warped with
/// `CGWarpMouseCursorPosition`. Coordinates are read and written in Quartz
/// global display space (origin top-left, +Y downward) while Flux logical
/// deltas use +Y upward, so only the vertical component is negated at the
/// boundary.
@MainActor
final class MacOSPointerController {
    /// Private marker written into `eventSourceUserData` on every synthetic
    /// event (design spec §7). The event tap reads this field and passes
    /// marked events through untouched so Flux output never loops back into
    /// Flux input.
    static let syntheticEventMarker: Int64 = 0x4658_0001

    /// The owned pointer motion sequence; every move advances it and
    /// `resetMotion()` clears it.
    private var motionState: PointerMotionState

    init(profile: PointerMotionProfile = .default) {
        self.motionState = PointerMotionState(profile: profile)
    }

    /// Moves the pointer one logical step in `direction`.
    ///
    /// Reads the current cursor location, advances `motionState` for the
    /// event (tiered acceleration is FluxCore's job, not this type's),
    /// flips the vertical component for Quartz's +Y-down screen space, and
    /// posts one `.mouseMoved` event to `.cghidEventTap`. Returns false
    /// when the current location or the move event cannot be created; the
    /// motion state is still advanced by the attempted event.
    @discardableResult
    func move(
        direction: Direction,
        fast: Bool,
        isRepeat: Bool,
        timestamp: TimeInterval
    ) -> Bool {
        guard let current = CGEvent(source: nil) else { return false }
        let delta = motionState.delta(
            direction: direction,
            fast: fast,
            isRepeat: isRepeat,
            timestamp: timestamp
        )
        // Flux logical coordinates are +Y up; Quartz screen coordinates are
        // +Y down, so the vertical component is negated (design spec §6).
        let target = CGPoint(
            x: current.location.x + delta.dx,
            y: current.location.y - delta.dy
        )
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: target,
            mouseButton: .left
        ) else { return false }
        event.setIntegerValueField(
            .eventSourceUserData,
            value: Self.syntheticEventMarker
        )
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Clicks the primary button the requested number of times.
    ///
    /// A single click posts one down/up pair with clickState 1; a double
    /// click posts two pairs with clickState 1 then 2. All events are
    /// created before any is posted, so a creation failure returns false
    /// without a partial click.
    @discardableResult
    func click(_ count: PointerClickCount) -> Bool {
        guard let current = CGEvent(source: nil) else { return false }
        let location = current.location

        let clickStates: [Int64]
        switch count {
        case .single:
            clickStates = [1]
        case .double:
            clickStates = [1, 2]
        }

        var events: [CGEvent] = []
        for state in clickStates {
            guard let down = Self.pressEvent(
                mouseType: .leftMouseDown,
                location: location,
                clickState: state
            ), let up = Self.pressEvent(
                mouseType: .leftMouseUp,
                location: location,
                clickState: state
            ) else {
                return false
            }
            events.append(down)
            events.append(up)
        }

        for event in events {
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Clears the motion sequence; the next move starts at the normal tier.
    func resetMotion() {
        motionState.reset()
    }

    /// A left-button press or release event with the click state and the
    /// private synthetic marker applied, or nil when the event cannot be
    /// created.
    private static func pressEvent(
        mouseType: CGEventType,
        location: CGPoint,
        clickState: Int64
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else { return nil }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.setIntegerValueField(
            .eventSourceUserData,
            value: syntheticEventMarker
        )
        return event
    }
}
