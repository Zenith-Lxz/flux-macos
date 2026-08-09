import Testing
@testable import FluxApp

struct EventTapLifecycleStateTests {
    @Test func startsAndStopsDeterministically() {
        var state = EventTapLifecycleState()
        #expect(!state.isRunning)

        state.didStart()
        #expect(state.isRunning)

        state.didStop()
        #expect(!state.isRunning)
    }

    @Test func successfulRecoveryKeepsInputRunning() {
        var state = EventTapLifecycleState()
        state.didStart()

        let outcome = state.reconcileRecovery(
            hasTap: true,
            isEnabledAfterAttempt: true
        )

        #expect(outcome == .recovered)
        #expect(state.isRunning)
    }

    @Test func failedRecoveryClearsRunningStateImmediately() {
        for evidence in [(false, false), (true, false)] {
            var state = EventTapLifecycleState()
            state.didStart()

            let outcome = state.reconcileRecovery(
                hasTap: evidence.0,
                isEnabledAfterAttempt: evidence.1
            )

            #expect(outcome == .failedClosed)
            #expect(!state.isRunning)
        }
    }

    @Test func lateRecoveryCallbackAfterStopIsIgnored() {
        var state = EventTapLifecycleState()
        state.didStart()
        state.didStop()

        let outcome = state.reconcileRecovery(
            hasTap: true,
            isEnabledAfterAttempt: false
        )

        #expect(outcome == .ignored)
        #expect(!state.isRunning)
    }
}
