// FluxCore.Context — platform-neutral coordinator for the Return race.
//
// A single Caps press asks Flux to activate the previous context while macOS
// concurrently reports frontmost-app notifications. `ContextCoordinator`
// owns the `ContextHistory` state machine and serializes that race: the
// exact candidate and current source are captured before the async
// activation, observations that arrive while activation is in flight are
// queued in arrival order (not applied), and the queued notifications are
// replayed only after the transaction resolves. The type contains no
// AppKit/CoreGraphics or Accessibility code; the real activator (CGEvent /
// NSRunningApplication activation) is injected behind `ContextTargetActivating`
// so the coordinator stays unit-testable without macOS permissions
// (design spec §7: platform boundaries are injected behind protocols).

/// Performs an asynchronous activation of a target context.
///
/// The platform layer implements this with its real application-switching
/// mechanism. The coordinator treats the returned `Bool` as the activation
/// result and never assumes success from the absence of an error.
@MainActor
public protocol ContextTargetActivating: AnyObject {
    /// Activates `target` and reports whether activation actually happened.
    func activate(_ target: ContextSnapshot) async -> Bool
}

/// Serializes a Return activation against concurrent context observations.
///
/// The race this coordinator resolves: a Return is issued for
/// `history.previous`, the platform activation takes time, and macOS keeps
/// emitting frontmost-app notifications while it is in flight. Applying
/// those notifications immediately would shift history under the Return.
/// Instead observations are queued in arrival order while activation is in
/// flight and replayed after the transaction resolves, so the activation
/// notification for the returned target lands as an exact duplicate of the
/// committed current context and cannot corrupt the A ↔ B toggle
/// (design spec §4).
@MainActor
public final class ContextCoordinator {
    /// The observed context history.
    public private(set) var history: ContextHistory
    /// Whether a Return activation is currently awaiting its activator.
    public private(set) var isReturnInFlight = false

    private let activator: any ContextTargetActivating

    /// Observations received while a Return is in flight, in arrival order.
    private var queuedObservations: [ContextSnapshot] = []

    /// Monotonic token for the current generation of Return operations.
    ///
    /// `reset` bumps the token and drops the in-flight operation; a
    /// completion that resumes after the bump sees a stale generation and
    /// returns false without touching the reset state.
    private var returnGeneration = 0

    /// The transaction captured before an activation await.
    private struct InFlightReturn {
        let generation: Int
        /// The exact candidate captured before the await.
        let candidate: ContextSnapshot
        /// The current source captured before the await.
        let source: ContextSnapshot?
    }

    private var inFlight: InFlightReturn?

    public init(
        initial: ContextSnapshot? = nil,
        activator: any ContextTargetActivating
    ) {
        history = ContextHistory(initial: initial)
        self.activator = activator
    }

    /// Records an observed frontmost context.
    ///
    /// While a Return is in flight the observation is queued in arrival
    /// order and applied only after the activation resolves; otherwise it is
    /// applied to `history` immediately.
    public func observe(_ snapshot: ContextSnapshot) {
        if isReturnInFlight {
            queuedObservations.append(snapshot)
        } else {
            history.observe(snapshot)
        }
    }

    /// Records that process `pid` terminated.
    ///
    /// The stored history and every queued observation matching `pid` keep
    /// their bundle identifier but drop process and window identity, so the
    /// application remains a relaunchable target.
    public func markProcessTerminated(_ pid: Int32) {
        history.markProcessTerminated(pid)
        guard isReturnInFlight else { return }
        queuedObservations = queuedObservations.map { snapshot in
            guard snapshot.processIdentifier == pid else { return snapshot }
            return ContextSnapshot(
                bundleIdentifier: snapshot.bundleIdentifier,
                processIdentifier: nil,
                windowIdentifier: nil
            )
        }
    }

    /// Activates the previous context and returns whether the Return
    /// transaction completed.
    ///
    /// Returns false without calling the activator when there is no previous
    /// candidate or when another Return is already in flight. The exact
    /// candidate and current source are captured before the await. While
    /// activation is in flight, observations queue instead of shifting
    /// history. On activator success the captured candidate is committed
    /// transactionally (a stale candidate fails without mutation) and the
    /// queued observations replay; the caller learns true only when both the
    /// activation and the commit succeeded. On activator failure history is
    /// not committed, but queued observations still replay.
    @discardableResult
    public func returnToPrevious() async -> Bool {
        guard !isReturnInFlight, let candidate = history.returnCandidate else {
            return false
        }
        let generation = returnGeneration
        let source = history.current
        isReturnInFlight = true
        inFlight = InFlightReturn(generation: generation, candidate: candidate, source: source)
        let activationSucceeded = await activator.activate(candidate)
        guard let flight = inFlight, flight.generation == generation else {
            // A reset invalidated this operation; its stale completion must
            // not mutate the reset state.
            return false
        }
        defer {
            inFlight = nil
            isReturnInFlight = false
            queuedObservations.removeAll()
        }
        guard activationSucceeded else {
            replayQueuedObservations()
            return false
        }
        let committed = history.commitReturn(to: flight.candidate)
        replayQueuedObservations()
        return committed
    }

    /// Resets history and abandons any in-flight Return.
    ///
    /// The queue and in-flight flag are cleared and the operation generation
    /// is bumped, so the outstanding activation's later completion observes a
    /// stale token and returns false without mutating the reset state. A new
    /// Return may begin immediately.
    public func reset(initial: ContextSnapshot? = nil) {
        returnGeneration += 1
        inFlight = nil
        isReturnInFlight = false
        queuedObservations.removeAll()
        history.reset(initial: initial)
    }

    private func replayQueuedObservations() {
        let pending = queuedObservations
        queuedObservations.removeAll()
        for snapshot in pending {
            history.observe(snapshot)
        }
    }
}
