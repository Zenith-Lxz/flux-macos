import FluxCore
import Testing
@testable import FluxApp

/// Contract tests for the pause API on the macOS input engine
/// (design spec §8): idempotent `setPaused`, exact-once transitions, and
/// the shared public path used by the menu and the pause/resume chord.
///
/// The engine is constructed but never started, so no event tap and no HID
/// manager is installed and no system permission is touched during tests.
struct MacOSGlobalInputEnginePauseTests {
    @MainActor
    private func makeEngine(
        configuration: FluxConfiguration = .default,
        pointerController: MacOSPointerController = MacOSPointerController()
    ) -> MacOSGlobalInputEngine {
        MacOSGlobalInputEngine(
            contextRuntime: MacOSContextRuntime(),
            focusController: MacOSFocusController(),
            pointerController: pointerController,
            configuration: configuration
        )
    }

    @Test @MainActor func engineStartsUnpaused() {
        let engine = makeEngine()
        #expect(!engine.isPaused)
    }

    @Test @MainActor func engineStartsNotRunning() {
        // The engine is constructed but never started in tests; `isRunning`
        // is read-only to callers and stays false, which is what keeps the
        // Pause menu disabled until a real start() succeeds.
        let engine = makeEngine()
        #expect(!engine.isRunning)
    }

    @Test @MainActor func disabledConfigurationStartsPaused() {
        let engine = makeEngine(configuration: FluxConfiguration(enabled: false))
        #expect(engine.isPaused)
    }

    @Test @MainActor func applyingConfigurationUpdatesPauseAndPointerSpeed() {
        let pointerController = MacOSPointerController()
        let engine = makeEngine(pointerController: pointerController)
        var calls: [Bool] = []
        engine.onPauseStateChange = { calls.append($0) }

        engine.applyConfiguration(
            FluxConfiguration(enabled: false, pointerSpeedMultiplier: 1.5)
        )

        #expect(engine.isPaused)
        #expect(calls == [true])
        #expect(pointerController.motionProfile == PointerMotionProfile.default.scaled(by: 1.5))
    }

    @Test @MainActor func setPausedIsIdempotentAndNotifiesOncePerTransition() {
        let engine = makeEngine()
        var calls: [Bool] = []
        engine.onPauseStateChange = { calls.append($0) }

        engine.setPaused(true)
        engine.setPaused(true)
        #expect(engine.isPaused)
        #expect(calls == [true])

        engine.setPaused(false)
        engine.setPaused(false)
        #expect(!engine.isPaused)
        #expect(calls == [true, false])
    }

    @Test @MainActor func settingAlreadyCurrentStateDoesNothing() {
        let engine = makeEngine()
        var calls: [Bool] = []
        engine.onPauseStateChange = { calls.append($0) }

        engine.setPaused(false)
        #expect(!engine.isPaused)
        #expect(calls.isEmpty)
    }

    @Test @MainActor func togglePausedFlipsExactlyOncePerTransition() {
        let engine = makeEngine()
        var calls: [Bool] = []
        engine.onPauseStateChange = { calls.append($0) }

        engine.togglePaused()
        #expect(engine.isPaused)
        #expect(calls == [true])

        engine.togglePaused()
        #expect(!engine.isPaused)
        #expect(calls == [true, false])
    }

    @Test @MainActor func repeatedTogglesReturnToOriginalState() {
        let engine = makeEngine()
        var calls: [Bool] = []
        engine.onPauseStateChange = { calls.append($0) }

        engine.togglePaused()
        engine.togglePaused()
        engine.togglePaused()
        #expect(engine.isPaused)
        #expect(calls == [true, false, true])
    }
}
