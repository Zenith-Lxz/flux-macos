import Testing
@testable import FluxApp

struct AppRuntimeStatusTests {
    @Test func missingPermissionsAlwaysWin() {
        #expect(AppRuntimeStatus.resolve(
            permissionReady: false,
            inputEngineRunning: false,
            paused: true,
            contextReturnFailed: true
        ) == .permissionsNeeded)
    }

    @Test func listeningFailureWinsOverStalePauseState() {
        #expect(AppRuntimeStatus.resolve(
            permissionReady: true,
            inputEngineRunning: false,
            paused: true,
            contextReturnFailed: true
        ) == .listeningFailed)
    }

    @Test func contextReturnFailureIsVisibleWhileRunning() {
        #expect(AppRuntimeStatus.resolve(
            permissionReady: true,
            inputEngineRunning: true,
            paused: false,
            contextReturnFailed: true
        ) == .contextReturnFailed)
    }

    @Test func pauseWinsOverTransientContextReturnFailure() {
        #expect(AppRuntimeStatus.resolve(
            permissionReady: true,
            inputEngineRunning: true,
            paused: true,
            contextReturnFailed: true
        ) == .paused)
    }

    @Test func pauseRequiresARunningEngine() {
        #expect(AppRuntimeStatus.resolve(
            permissionReady: true,
            inputEngineRunning: true,
            paused: true,
            contextReturnFailed: false
        ) == .paused)
    }

    @Test func readyRunningUnpausedIsRunning() {
        #expect(AppRuntimeStatus.resolve(
            permissionReady: true,
            inputEngineRunning: true,
            paused: false,
            contextReturnFailed: false
        ) == .running)
    }
}
