import Testing
@testable import FluxCore

// MARK: - Helpers

private func snap(
    _ bundleIdentifier: String,
    _ processIdentifier: Int32? = nil,
    _ windowIdentifier: String? = nil
) -> ContextSnapshot {
    ContextSnapshot(
        bundleIdentifier: bundleIdentifier,
        processIdentifier: processIdentifier,
        windowIdentifier: windowIdentifier
    )
}

/// Deterministic, race-free fake activator.
///
/// `activate` records the target and suspends on a checked continuation
/// until the test resumes it explicitly, so every in-flight window is fully
/// controlled from the main actor. No sleeps or timing assumptions.
@MainActor
private final class ControllableActivator: ContextTargetActivating {
    private(set) var calls: [ContextSnapshot] = []
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    func activate(_ target: ContextSnapshot) async -> Bool {
        calls.append(target)
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    /// Resumes the oldest outstanding activation with `success`.
    func completeFirst(success: Bool) {
        continuations.removeFirst().resume(returning: success)
    }
}

/// Yields until `condition` holds. All parties are main-actor tasks, so the
/// cooperative scheduling converges deterministically without timing waits.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    while !condition() {
        await Task.yield()
    }
}

// MARK: - No previous candidate

@MainActor
struct ContextCoordinatorNoCandidateTests {
    @Test func singleContextHasNoReturnCandidate() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)

        let result = await coordinator.returnToPrevious()

        #expect(result == false)
        #expect(activator.calls.isEmpty)
        #expect(!coordinator.isReturnInFlight)
        #expect(coordinator.history.current == snap("A", 1, "a1"))
        #expect(coordinator.history.previous == nil)
    }

    @Test func emptyHistoryHasNoReturnCandidate() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(activator: activator)

        let result = await coordinator.returnToPrevious()

        #expect(result == false)
        #expect(activator.calls.isEmpty)
        #expect(!coordinator.isReturnInFlight)
    }
}

// MARK: - Successful A/B swap

@MainActor
struct ContextCoordinatorReturnTests {
    @Test func successfulABSwapCommits() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)
        coordinator.observe(snap("B", 2, "b1"))

        let task = Task { await coordinator.returnToPrevious() }
        await waitUntil { activator.calls.count == 1 }
        #expect(activator.calls.first == snap("A", 1, "a1"))
        #expect(coordinator.isReturnInFlight)

        activator.completeFirst(success: true)
        let result = await task.value

        #expect(result == true)
        #expect(coordinator.history.current == snap("A", 1, "a1"))
        #expect(coordinator.history.previous == snap("B", 2, "b1"))
        #expect(!coordinator.isReturnInFlight)
    }

    @Test func activationFailurePreservesHistory() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)
        coordinator.observe(snap("B", 2, "b1"))

        let task = Task { await coordinator.returnToPrevious() }
        await waitUntil { activator.calls.count == 1 }
        activator.completeFirst(success: false)
        let result = await task.value

        #expect(result == false)
        // No commit: history keeps its A/B layout.
        #expect(coordinator.history.current == snap("B", 2, "b1"))
        #expect(coordinator.history.previous == snap("A", 1, "a1"))
        #expect(!coordinator.isReturnInFlight)
    }

    @Test func activationFailureStillReplaysQueuedObservations() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)
        coordinator.observe(snap("B", 2, "b1"))

        let task = Task { await coordinator.returnToPrevious() }
        await waitUntil { activator.calls.count == 1 }
        coordinator.observe(snap("C", 3, "c1"))
        activator.completeFirst(success: false)
        let result = await task.value

        #expect(result == false)
        // No swap, but the real queued observation still applies in order.
        #expect(coordinator.history.current == snap("C", 3, "c1"))
        #expect(coordinator.history.previous == snap("B", 2, "b1"))
        #expect(!coordinator.isReturnInFlight)
    }

    @Test func targetActivationNotificationDoesNotCorruptToggle() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)
        coordinator.observe(snap("B", 2, "b1"))

        let task = Task { await coordinator.returnToPrevious() }
        await waitUntil { activator.calls.count == 1 }
        // macOS reports the target frontmost while activation is in flight.
        coordinator.observe(snap("A", 1, "a1"))
        activator.completeFirst(success: true)
        let result = await task.value

        #expect(result == true)
        // The activation notification is an exact duplicate of the committed
        // current context and cannot shift the A/B toggle.
        #expect(coordinator.history.current == snap("A", 1, "a1"))
        #expect(coordinator.history.previous == snap("B", 2, "b1"))
        #expect(!coordinator.isReturnInFlight)
    }

    @Test func unrelatedNotificationsReplayInArrivalOrder() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)
        coordinator.observe(snap("B", 2, "b1"))

        let task = Task { await coordinator.returnToPrevious() }
        await waitUntil { activator.calls.count == 1 }
        coordinator.observe(snap("C", 3, "c1"))
        coordinator.observe(snap("D", 4, "d1"))
        activator.completeFirst(success: true)
        let result = await task.value

        #expect(result == true)
        // Commit swaps to A, then queued observations apply in arrival order.
        #expect(coordinator.history.current == snap("D", 4, "d1"))
        #expect(coordinator.history.previous == snap("C", 3, "c1"))
        #expect(!coordinator.isReturnInFlight)
    }

    @Test func secondConcurrentReturnIsRejected() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)
        coordinator.observe(snap("B", 2, "b1"))

        let first = Task { await coordinator.returnToPrevious() }
        await waitUntil { activator.calls.count == 1 }

        let second = await coordinator.returnToPrevious()
        #expect(second == false)

        activator.completeFirst(success: true)
        let firstResult = await first.value
        #expect(firstResult == true)
        // Exactly one activation was issued despite two Return requests.
        #expect(activator.calls.count == 1)
        #expect(!coordinator.isReturnInFlight)
    }

    @Test func terminatedCandidateFailsTransactionallyAndKeepsQueue() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)
        coordinator.observe(snap("B", 2, "b1"))

        let task = Task { await coordinator.returnToPrevious() }
        await waitUntil { activator.calls.count == 1 }
        coordinator.observe(snap("C", 3, "c1"))
        // The candidate's process dies while activation is in flight; the
        // stored previous keeps its bundle as a relaunchable target, which
        // no longer equals the captured candidate.
        coordinator.markProcessTerminated(1)
        activator.completeFirst(success: true)
        let result = await task.value

        #expect(result == false)
        // The commit failed transactionally; the real queued observation was
        // not discarded and still replayed.
        #expect(coordinator.history.current == snap("C", 3, "c1"))
        #expect(coordinator.history.previous == snap("B", 2, "b1"))
        #expect(!coordinator.isReturnInFlight)
    }
}

// MARK: - Process termination during in-flight

@MainActor
struct ContextCoordinatorTerminationTests {
    @Test func terminationClearsQueuedObservationsForMatchingPid() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)
        coordinator.observe(snap("B", 2, "b1"))

        let task = Task { await coordinator.returnToPrevious() }
        await waitUntil { activator.calls.count == 1 }
        coordinator.observe(snap("C", 3, "c1"))
        coordinator.observe(snap("D", 4, "d1"))
        // C dies while queued: its queued copy keeps the bundle but loses
        // process and window identity. D is untouched.
        coordinator.markProcessTerminated(3)
        activator.completeFirst(success: true)
        let result = await task.value

        #expect(result == true)
        #expect(coordinator.history.current == snap("D", 4, "d1"))
        #expect(coordinator.history.previous == snap("C", nil, nil))
        #expect(!coordinator.isReturnInFlight)
    }

    @Test func terminationOfUnrelatedPidLeavesQueueUnchanged() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)
        coordinator.observe(snap("B", 2, "b1"))

        let task = Task { await coordinator.returnToPrevious() }
        await waitUntil { activator.calls.count == 1 }
        coordinator.observe(snap("C", 3, "c1"))
        coordinator.markProcessTerminated(9)
        activator.completeFirst(success: true)
        let result = await task.value

        #expect(result == true)
        #expect(coordinator.history.current == snap("C", 3, "c1"))
        #expect(coordinator.history.previous == snap("A", 1, "a1"))
        #expect(!coordinator.isReturnInFlight)
    }

    @Test func terminationOutsideInFlightUpdatesHistoryOnly() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)
        coordinator.observe(snap("B", 2, "b1"))
        coordinator.observe(snap("C", 3, "c1"))

        coordinator.markProcessTerminated(3)

        #expect(coordinator.history.current == snap("C", nil, nil))
        #expect(coordinator.history.previous == snap("B", 2, "b1"))
        #expect(activator.calls.isEmpty)
    }
}

// MARK: - Reset

@MainActor
struct ContextCoordinatorResetTests {
    @Test func resetInvalidatesOutstandingCompletionAndPermitsLaterReturn() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)
        coordinator.observe(snap("B", 2, "b1"))

        let stale = Task { await coordinator.returnToPrevious() }
        await waitUntil { activator.calls.count == 1 }

        coordinator.reset(initial: snap("X", 9, "x1"))
        #expect(!coordinator.isReturnInFlight)
        #expect(coordinator.history.current == snap("X", 9, "x1"))
        #expect(coordinator.history.previous == nil)

        // The outstanding activation completes late; its stale completion
        // must not mutate the reset state.
        activator.completeFirst(success: true)
        let staleResult = await stale.value
        #expect(staleResult == false)
        #expect(coordinator.history.current == snap("X", 9, "x1"))
        #expect(coordinator.history.previous == nil)

        // A fresh Return works against the reset state.
        coordinator.observe(snap("Y", 8, "y1"))
        let fresh = Task { await coordinator.returnToPrevious() }
        await waitUntil { activator.calls.count == 2 }
        #expect(coordinator.isReturnInFlight)
        activator.completeFirst(success: true)
        let freshResult = await fresh.value
        #expect(freshResult == true)
        #expect(coordinator.history.current == snap("X", 9, "x1"))
        #expect(coordinator.history.previous == snap("Y", 8, "y1"))
        #expect(!coordinator.isReturnInFlight)
    }

    @Test func resetDuringInFlightDropsQueuedObservations() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)
        coordinator.observe(snap("B", 2, "b1"))

        let task = Task { await coordinator.returnToPrevious() }
        await waitUntil { activator.calls.count == 1 }
        coordinator.observe(snap("C", 3, "c1"))
        coordinator.observe(snap("D", 4, "d1"))
        coordinator.reset()
        activator.completeFirst(success: true)
        let result = await task.value

        #expect(result == false)
        // Reset cleared history; the dropped queue never surfaces.
        #expect(coordinator.history.current == nil)
        #expect(coordinator.history.previous == nil)
        #expect(!coordinator.isReturnInFlight)
    }
}

// MARK: - In-flight flag and compile-time isolation

@MainActor
struct ContextCoordinatorFlagTests {
    @Test func inFlightFlagTransitionsAcrossLifecycle() async {
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(initial: snap("A", 1, "a1"), activator: activator)
        coordinator.observe(snap("B", 2, "b1"))
        #expect(!coordinator.isReturnInFlight)

        let task = Task { await coordinator.returnToPrevious() }
        await waitUntil { activator.calls.count == 1 }
        #expect(coordinator.isReturnInFlight)

        // A rejected concurrent Return does not clear the flag.
        _ = await coordinator.returnToPrevious()
        #expect(coordinator.isReturnInFlight)

        activator.completeFirst(success: false)
        let result = await task.value
        #expect(result == false)
        #expect(!coordinator.isReturnInFlight)
    }

    @Test func compileTimeMainActorUsage() async {
        // The coordinator, protocol, and activator are MainActor-isolated;
        // this suite is @MainActor, so all of the following only type-check
        // under that isolation. A non-isolated context cannot reference them.
        let activator = ControllableActivator()
        let coordinator = ContextCoordinator(activator: activator)
        coordinator.observe(snap("A", 1))
        #expect(!coordinator.isReturnInFlight)
        _ = await coordinator.returnToPrevious()
        #expect(activator.calls.isEmpty)
    }
}
