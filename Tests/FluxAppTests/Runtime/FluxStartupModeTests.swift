import Testing
@testable import FluxApp

struct FluxStartupModeTests {
    @Test func ordinaryEnvironmentUsesNormalStartup() {
        let mode = FluxStartupMode(environment: [:])

        #expect(mode == .normal)
        #expect(mode.effectivePermissionSnapshot(
            actual: PermissionSnapshot(
                accessibilityTrusted: true,
                inputMonitoring: .granted
            )
        ).isReady)
        #expect(!mode.shouldExitAfterStartup)
    }

    @Test func noPermissionSmokeForcesDeniedPermissionsAndExits() {
        let mode = FluxStartupMode(environment: [
            FluxStartupMode.noPermissionSmokeEnvironmentKey: "1",
        ])

        #expect(mode == .noPermissionSmoke)
        #expect(mode.effectivePermissionSnapshot(
            actual: PermissionSnapshot(
                accessibilityTrusted: true,
                inputMonitoring: .granted
            )
        ) == PermissionSnapshot(
            accessibilityTrusted: false,
            inputMonitoring: .denied
        ))
        #expect(mode.shouldExitAfterStartup)
    }

    @Test func unrelatedEnvironmentValueCannotEnableSmokeMode() {
        let mode = FluxStartupMode(environment: [
            FluxStartupMode.noPermissionSmokeEnvironmentKey: "true",
        ])

        #expect(mode == .normal)
    }
}
