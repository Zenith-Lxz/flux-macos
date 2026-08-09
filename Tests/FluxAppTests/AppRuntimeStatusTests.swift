import Testing
@testable import FluxApp

struct AppRuntimeStatusTests {
    @Test func missingPermissionsAlwaysWin() {
        #expect(AppRuntimeStatus.resolve(
            permissionReady: false,
            inputEngineRunning: false,
            paused: true
        ) == .permissionsNeeded)
    }

    @Test func listeningFailureWinsOverStalePauseState() {
        #expect(AppRuntimeStatus.resolve(
            permissionReady: true,
            inputEngineRunning: false,
            paused: true
        ) == .listeningFailed)
    }

    @Test func pauseRequiresARunningEngine() {
        #expect(AppRuntimeStatus.resolve(
            permissionReady: true,
            inputEngineRunning: true,
            paused: true
        ) == .paused)
    }

    @Test func readyRunningUnpausedIsRunning() {
        #expect(AppRuntimeStatus.resolve(
            permissionReady: true,
            inputEngineRunning: true,
            paused: false
        ) == .running)
    }
}
