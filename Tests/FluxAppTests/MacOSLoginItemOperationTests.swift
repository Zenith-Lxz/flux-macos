import ServiceManagement
import Testing
@testable import FluxApp

/// Contract tests for the pure login-item toggle decision (design spec
/// §7.1): every status the current SDK defines maps to exactly one
/// operation, and the decision is a pure function — asserting it never
/// calls `register()`/`unregister()`, so verification never mutates the
/// real login item.
struct MacOSLoginItemOperationTests {
    @Test @MainActor func statusIsReadableWithoutSideEffects() {
        // Reading the real SMAppService status must not register or
        // unregister anything; the toggle path is deliberately not
        // exercised during verification.
        let controller = MacOSLoginItemController()
        switch controller.status {
        case .notRegistered, .enabled, .requiresApproval, .notFound:
            break
        @unknown default:
            Issue.record("unexpected SMAppService.Status")
        }
    }

    @Test @MainActor func enabledUnregisters() {
        #expect(MacOSLoginItemController.toggleOperation(for: .enabled) == .unregister)
    }

    @Test @MainActor func requiresApprovalUnregisters() {
        // A pending/denied approval still means the service is registered;
        // clicking the toggle again must turn it off by unregistering, not
        // re-request the approval (which would loop).
        #expect(MacOSLoginItemController.toggleOperation(for: .requiresApproval) == .unregister)
    }

    @Test @MainActor func notRegisteredRegisters() {
        #expect(MacOSLoginItemController.toggleOperation(for: .notRegistered) == .register)
    }

    @Test @MainActor func notFoundRegisters() {
        #expect(MacOSLoginItemController.toggleOperation(for: .notFound) == .register)
    }
}
