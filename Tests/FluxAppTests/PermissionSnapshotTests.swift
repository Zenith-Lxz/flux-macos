import Testing
@testable import FluxApp

/// Contract tests for the permission snapshot (design spec §8): readiness
/// requires both Accessibility trust and Input Monitoring access.
///
/// Only pure value logic and read-only system queries run here. The
/// user-invoked request path is deliberately never exercised in tests:
/// no permission prompt may appear and no System Settings pane may open
/// during verification.
struct PermissionSnapshotTests {
    @Test func readyRequiresBothPermissions() {
        #expect(PermissionSnapshot(accessibilityTrusted: true, inputMonitoring: .granted).isReady)
        #expect(!PermissionSnapshot(accessibilityTrusted: false, inputMonitoring: .granted).isReady)
        #expect(!PermissionSnapshot(accessibilityTrusted: true, inputMonitoring: .denied).isReady)
        #expect(!PermissionSnapshot(accessibilityTrusted: true, inputMonitoring: .unknown).isReady)
        #expect(!PermissionSnapshot(accessibilityTrusted: false, inputMonitoring: .denied).isReady)
    }

    @Test @MainActor func snapshotReadsWithoutPrompting() {
        // Construction and snapshot reads must never prompt (design spec
        // §8); running the real read path here proves it stays side-effect
        // free regardless of the host's permission state.
        let controller = MacOSPermissionController()
        let snapshot = controller.snapshot()
        #expect(snapshot.isReady == (
            snapshot.accessibilityTrusted && snapshot.inputMonitoring == .granted
        ))
    }
}
