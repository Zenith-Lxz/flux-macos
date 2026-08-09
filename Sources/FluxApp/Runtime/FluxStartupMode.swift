/// Process startup mode. The smoke-only mode is deliberately selected by one
/// exact environment value, forces a permission-denied snapshot, and exits
/// after AppKit lifecycle setup. It therefore exercises the assembled app's
/// no-permission path without ever installing the HID manager or event tap.
enum FluxStartupMode: Sendable, Equatable {
    case normal
    case noPermissionSmoke

    static let noPermissionSmokeEnvironmentKey = "FLUX_STARTUP_SMOKE_NO_PERMISSIONS"
    static let noPermissionSmokeSuccessLine =
        "FLUX STARTUP SMOKE PASS: permissions unavailable; input engine not started"

    init(environment: [String: String]) {
        self = environment[Self.noPermissionSmokeEnvironmentKey] == "1"
            ? .noPermissionSmoke
            : .normal
    }

    func effectivePermissionSnapshot(actual: PermissionSnapshot) -> PermissionSnapshot {
        switch self {
        case .normal:
            return actual
        case .noPermissionSmoke:
            return PermissionSnapshot(
                accessibilityTrusted: false,
                inputMonitoring: .denied
            )
        }
    }

    var shouldExitAfterStartup: Bool {
        self == .noPermissionSmoke
    }
}
