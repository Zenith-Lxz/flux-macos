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

/// Compile-time proof that the argument conforms to `Sendable`.
private func requireSendable<T: Sendable>(_ value: T) {}

// MARK: - ContextSnapshot

struct ContextSnapshotTests {
    @Test func equalityCoversAllIdentityFields() {
        #expect(snap("A", 1, "w1") == snap("A", 1, "w1"))
        #expect(snap("A", 1, "w1") != snap("B", 1, "w1"))
        #expect(snap("A", 1, "w1") != snap("A", 2, "w1"))
        #expect(snap("A", 1, "w1") != snap("A", 1, "w2"))
        #expect(snap("A", 1, nil) != snap("A", 1, "w1"))
        #expect(snap("A", nil, "w1") != snap("A", 1, "w1"))
    }

    @Test func hashMatchesEquality() {
        let snapshots = [
            snap("A", 1, "w1"), snap("A", 1, "w1"),
            snap("A", 2, "w1"), snap("A", 1, "w2"),
        ]
        #expect(Set(snapshots).count == 3)
        #expect(Set([snap("A", 1, "w1"), snap("A", 1, "w1")]).count == 1)
    }
}

// MARK: - Empty and initial state

struct ContextHistoryInitialStateTests {
    @Test func emptyStateHasNoCurrentOrPrevious() {
        let history = ContextHistory()
        #expect(history.current == nil)
        #expect(history.previous == nil)
        #expect(history.returnCandidate == nil)
    }

    @Test func initialSnapshotBecomesCurrentWithoutPrevious() {
        let history = ContextHistory(initial: snap("A", 1, "a1"))
        #expect(history.current == snap("A", 1, "a1"))
        #expect(history.previous == nil)
        #expect(history.returnCandidate == nil)
    }
}

// MARK: - Observation

struct ContextHistoryObservationTests {
    @Test func firstObservationBecomesCurrent() {
        var history = ContextHistory()
        history.observe(snap("A", 1, "a1"))
        #expect(history.current == snap("A", 1, "a1"))
        #expect(history.previous == nil)
    }

    @Test func exactDuplicateObservationIsIgnored() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        history.observe(snap("A", 1, "a1"))
        #expect(history.current == snap("A", 1, "a1"))
        #expect(history.previous == nil)
        // Repeated duplicates never create a previous context.
        history.observe(snap("A", 1, "a1"))
        history.observe(snap("A", 1, "a1"))
        #expect(history.current == snap("A", 1, "a1"))
        #expect(history.previous == nil)
    }

    @Test func secondObservationBecomesPrevious() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        history.observe(snap("B", 2, "b1"))
        #expect(history.current == snap("B", 2, "b1"))
        #expect(history.previous == snap("A", 1, "a1"))
    }

    @Test func sameApplicationDifferentWindowIsNewContext() {
        var history = ContextHistory(initial: snap("A", 1, "w1"))
        history.observe(snap("A", 1, "w2"))
        #expect(history.current == snap("A", 1, "w2"))
        #expect(history.previous == snap("A", 1, "w1"))
    }

    @Test func sameApplicationDifferentProcessIsNewContext() {
        var history = ContextHistory(initial: snap("A", 1, "w1"))
        history.observe(snap("A", 2, "w1"))
        #expect(history.current == snap("A", 2, "w1"))
        #expect(history.previous == snap("A", 1, "w1"))
    }

    @Test func reObservingPreviousContextMakesItCurrent() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        history.observe(snap("B", 2, "b1"))
        history.observe(snap("A", 1, "a1"))
        #expect(history.current == snap("A", 1, "a1"))
        #expect(history.previous == snap("B", 2, "b1"))
    }
}

// MARK: - Return candidate and commit

struct ContextHistoryReturnTests {
    @Test func returnCandidateIsPreviousWithoutMutation() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        history.observe(snap("B", 2, "b1"))
        #expect(history.returnCandidate == snap("A", 1, "a1"))
        #expect(history.current == snap("B", 2, "b1"))
        #expect(history.previous == snap("A", 1, "a1"))
        // Reading the candidate repeatedly stays non-mutating.
        #expect(history.returnCandidate == snap("A", 1, "a1"))
        #expect(history.current == snap("B", 2, "b1"))
        #expect(history.previous == snap("A", 1, "a1"))
    }

    @Test func successfulCommitSwapsCurrentAndPrevious() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        history.observe(snap("B", 2, "b1"))
        #expect(history.commitReturn(to: snap("A", 1, "a1")) == true)
        #expect(history.current == snap("A", 1, "a1"))
        #expect(history.previous == snap("B", 2, "b1"))
    }

    @Test func repeatedCommitsToggleBetweenAAndB() {
        let a = snap("A", 1, "a1")
        let b = snap("B", 2, "b1")
        var history = ContextHistory(initial: a)
        history.observe(b)
        for _ in 0..<3 {
            #expect(history.commitReturn(to: a) == true)
            #expect(history.current == a)
            #expect(history.previous == b)
            #expect(history.commitReturn(to: b) == true)
            #expect(history.current == b)
            #expect(history.previous == a)
        }
    }

    @Test func staleCandidateFailsTransactionally() {
        let a = snap("A", 1, "a1")
        let b = snap("B", 2, "b1")
        let c = snap("C", 3, "c1")
        var history = ContextHistory(initial: a)
        history.observe(b)
        history.observe(c)
        // `a` is no longer previous; the commit fails and mutates nothing.
        #expect(history.commitReturn(to: a) == false)
        #expect(history.current == c)
        #expect(history.previous == b)
        // Committing the current context (not the previous) also fails.
        #expect(history.commitReturn(to: c) == false)
        #expect(history.current == c)
        #expect(history.previous == b)
        // The up-to-date candidate still succeeds afterwards.
        #expect(history.commitReturn(to: b) == true)
        #expect(history.current == b)
        #expect(history.previous == c)
    }

    @Test func commitWithNoPreviousIsImpossible() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        #expect(history.commitReturn(to: snap("A", 1, "a1")) == false)
        #expect(history.current == snap("A", 1, "a1"))
        #expect(history.previous == nil)

        var empty = ContextHistory()
        #expect(empty.commitReturn(to: snap("A", 1, "a1")) == false)
        #expect(empty.current == nil)
        #expect(empty.previous == nil)
    }

    @Test func activationObservationAfterCommitDoesNotCorruptHistory() {
        let a = snap("A", 1, "a1")
        let b = snap("B", 2, "b1")
        var history = ContextHistory(initial: a)
        history.observe(b)
        #expect(history.commitReturn(to: a) == true)
        #expect(history.current == a)
        #expect(history.previous == b)
        // The activation event for the now-current app is an exact duplicate
        // and must not shift the history.
        history.observe(a)
        #expect(history.current == a)
        #expect(history.previous == b)
        // Return still goes back to B.
        #expect(history.returnCandidate == b)
        #expect(history.commitReturn(to: b) == true)
        #expect(history.current == b)
        #expect(history.previous == a)
    }
}

// MARK: - Process termination

struct ContextHistoryTerminationTests {
    @Test func terminationClearsOnlyMatchingSnapshot() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        history.observe(snap("B", 2, "b1"))
        history.markProcessTerminated(1)
        #expect(history.current == snap("B", 2, "b1"))
        #expect(history.previous == snap("A", nil, nil))
    }

    @Test func terminationClearsCurrentSnapshot() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        history.observe(snap("B", 2, "b1"))
        history.markProcessTerminated(2)
        #expect(history.current == snap("B", nil, nil))
        #expect(history.previous == snap("A", 1, "a1"))
    }

    @Test func terminationLeavesOtherSnapshotsUnchanged() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        history.observe(snap("B", 2, "b1"))
        // No stored snapshot has process 3.
        history.markProcessTerminated(3)
        #expect(history.current == snap("B", 2, "b1"))
        #expect(history.previous == snap("A", 1, "a1"))
    }

    @Test func terminationKeepsBundleAsRelaunchableTarget() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        history.observe(snap("B", 2, "b1"))
        history.markProcessTerminated(1)
        // The previous slot keeps its bundle identifier so a Return can
        // relaunch the app (design spec §4 degradation path).
        #expect(history.returnCandidate == snap("A", nil, nil))
        #expect(history.commitReturn(to: snap("A", nil, nil)) == true)
        #expect(history.current == snap("A", nil, nil))
        #expect(history.previous == snap("B", 2, "b1"))
    }

    @Test func relaunchedProcessIsNewContextAfterTermination() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        history.markProcessTerminated(1)
        #expect(history.current == snap("A", nil, nil))
        // A fresh process of the same app is a new context.
        history.observe(snap("A", 5, "new-window"))
        #expect(history.current == snap("A", 5, "new-window"))
        #expect(history.previous == snap("A", nil, nil))
    }

    @Test func terminationIsIdempotentForClearedSnapshot() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        history.markProcessTerminated(1)
        history.markProcessTerminated(1)
        #expect(history.current == snap("A", nil, nil))
    }
}

// MARK: - Reset

struct ContextHistoryResetTests {
    @Test func resetClearsHistory() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        history.observe(snap("B", 2, "b1"))
        history.reset()
        #expect(history.current == nil)
        #expect(history.previous == nil)
        #expect(history.returnCandidate == nil)
    }

    @Test func resetWithInitialRestoresSingleContext() {
        var history = ContextHistory(initial: snap("A", 1, "a1"))
        history.observe(snap("B", 2, "b1"))
        history.reset(initial: snap("C", 3, "c1"))
        #expect(history.current == snap("C", 3, "c1"))
        #expect(history.previous == nil)
        // The fresh history observes normally again.
        history.observe(snap("D", 4, "d1"))
        #expect(history.current == snap("D", 4, "d1"))
        #expect(history.previous == snap("C", 3, "c1"))
    }
}

// MARK: - Sendable

struct ContextHistorySendableTests {
    @Test func snapshotAndHistoryAreSendable() {
        // Compile-time proof: the helper only accepts Sendable types.
        requireSendable(snap("com.apple.finder", 42, "window"))
        requireSendable(ContextHistory(initial: snap("com.apple.finder")))
        requireSendable(ContextHistory())
    }
}
