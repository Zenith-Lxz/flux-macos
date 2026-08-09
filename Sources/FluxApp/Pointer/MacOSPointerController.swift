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
    /// event (design spec §7). The value is the shared marker owned by
    /// `SyntheticEventMarker` so keyboard and pointer output carry the same
    /// marker; the event tap reads this field and passes marked events
    /// through untouched so Flux output never loops back into Flux input.
    static let syntheticEventMarker: Int64 = SyntheticEventMarker.value

    /// The owned pointer motion sequence; every move advances it and
    /// `resetMotion()` clears it.
    private var motionState: PointerMotionState

    /// Stable unscaled profile. Runtime speed updates always derive from
    /// this value, so repeated settings changes never compound rounding or
    /// scale an already-scaled profile.
    private let baseProfile: PointerMotionProfile

    /// The bounded Accessibility snapper (design spec §6). Constructed
    /// eagerly, but it performs no AX work until the first non-repeat move
    /// requests a snap point, so constructing the controller stays
    /// permission-free and side-effect-free.
    private let snapper: any PointerSnapping

    /// Generation of the latest pointer move. Every move advances it so a
    /// queued snap from an older move can be discarded before it posts.
    private var snapGeneration: UInt64 = 0

    init(
        profile: PointerMotionProfile = .default,
        snapper: any PointerSnapping = MacOSPointerSnapper()
    ) {
        self.baseProfile = profile
        self.motionState = PointerMotionState(profile: profile)
        self.snapper = snapper
    }

    /// Current effective profile, exposed internally for deterministic tests
    /// and settings reconciliation without touching the window server.
    var motionProfile: PointerMotionProfile {
        motionState.profile
    }

    /// Applies the bounded settings multiplier and starts a fresh motion
    /// sequence. Outstanding corrective snaps are invalidated as part of the
    /// same state transition.
    func updateSpeedMultiplier(_ multiplier: Double) {
        motionState = PointerMotionState(profile: baseProfile.scaled(by: multiplier))
        snapGeneration &+= 1
    }

    /// Moves the pointer one logical step in `direction`.
    ///
    /// Reads the current cursor location, advances `motionState` for the
    /// event (tiered acceleration is FluxCore's job, not this type's),
    /// flips the vertical component for Quartz's +Y-down screen space, and
    /// immediately posts the geometric `.mouseMoved` event. A non-repeat
    /// may later post one corrective snapped move outside the event-tap
    /// callback. Returns false when the current location or geometric move
    /// event cannot be created; the motion state is still advanced by the
    /// attempted event.
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
        let geometricTarget = CGPoint(
            x: current.location.x + delta.dx,
            y: current.location.y - delta.dy
        )
        guard postMouseMove(at: geometricTarget) else { return false }
        scheduleSnap(for: geometricTarget, isRepeat: isRepeat)
        return true
    }

    /// Returns a snap destination for one pointer move, or nil when the move
    /// must remain geometric (design spec §6).
    ///
    /// Auto-repeat never snaps: a held direction keeps pure tiered
    /// acceleration so it cannot get trapped snapping back to the same
    /// control. A non-repeat move asks the snapper for a nearby interactive
    /// AX target and adopts its point when one is returned; any failure
    /// falls back to the original geometric point, so pointer output is
    /// never blocked by the probe.
    internal func snapTarget(
        geometricTarget: CGPoint,
        isRepeat: Bool
    ) -> CGPoint? {
        guard !isRepeat else { return nil }
        return snapper.snapPoint(for: geometricTarget)
    }

    /// Schedules the AX probe after the event-tap callback can return. The
    /// geometric move has already been posted, so AX latency can never block
    /// the basic pointer output. Repeats only advance the generation, which
    /// cancels any older queued snap and preserves acceleration.
    private func scheduleSnap(for geometricTarget: CGPoint, isRepeat: Bool) {
        snapGeneration &+= 1
        let generation = snapGeneration
        guard !isRepeat else { return }
        Task { @MainActor [weak self] in
            guard let self, self.snapGeneration == generation,
                  let snapped = self.snapTarget(
                    geometricTarget: geometricTarget,
                    isRepeat: false
                  ), self.snapGeneration == generation else {
                return
            }
            _ = self.postMouseMove(at: snapped)
        }
    }

    /// Posts one marked pointer move at `target`.
    @discardableResult
    private func postMouseMove(at target: CGPoint) -> Bool {
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
        snapGeneration &+= 1
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
