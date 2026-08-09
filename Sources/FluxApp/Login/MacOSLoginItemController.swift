// FluxApp.Login — macOS login item control through the official API only.
//
// Uses only `SMAppService.mainApp` (design spec §7.1, §8): no LaunchAgent
// files and no fallback registration paths. Reading status never changes
// state; only the explicit user-invoked `toggle()` registers or
// unregisters. `init` performs no side effects, and the toggle path is
// never exercised during verification.
//
// Privacy boundary (design spec §8): failures are surfaced to the caller
// and logged only as NSError domain/code, never as full error descriptions
// that may embed local paths.

import ServiceManagement

/// What a user-invoked login-item toggle should do for one status. Pure
/// decision: `MacOSLoginItemController.toggle()` is the only place that
/// performs the actual register/unregister mutation.
enum LoginItemOperation: Sendable, Equatable {
    case register
    case unregister
}

/// Reads and toggles the app's real launch-at-login status.
@MainActor
final class MacOSLoginItemController {
    /// The current SMAppService status (read-only, no side effects).
    var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// The operation `toggle()` should perform for `status`.
    ///
    /// `.enabled` and `.requiresApproval` both mean the service is already
    /// registered (approval granted, or pending/denied), so clicking the
    /// toggle again turns it off by unregistering. `.notRegistered` and
    /// `.notFound` mean it is not active, so the toggle registers. Unknown
    /// future statuses conservatively register and let the caller surface
    /// any system rejection.
    static func toggleOperation(for status: SMAppService.Status) -> LoginItemOperation {
        switch status {
        case .enabled, .requiresApproval:
            return .unregister
        case .notRegistered, .notFound:
            return .register
        @unknown default:
            return .register
        }
    }

    /// Toggles launch at login: unregisters when the service is registered
    /// (`.enabled` or `.requiresApproval`), otherwise registers. Returns
    /// failure without any LaunchAgents fallback; the caller reports it.
    func toggle() -> Result<Void, Error> {
        let service = SMAppService.mainApp
        do {
            switch Self.toggleOperation(for: service.status) {
            case .unregister:
                try service.unregister()
            case .register:
                try service.register()
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
