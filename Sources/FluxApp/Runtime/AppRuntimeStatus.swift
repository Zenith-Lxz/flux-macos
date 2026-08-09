/// User-visible Flux runtime state, ordered by operational priority.
enum AppRuntimeStatus: Sendable, Equatable {
    case permissionsNeeded
    case listeningFailed
    case paused
    case running

    /// Resolves the state shown in the menu bar.
    ///
    /// Missing permissions are always actionable first. Once permissions
    /// are ready, a stopped input engine is a listening failure even if a
    /// stale pause preference remains set; paused is meaningful only while
    /// the engine is actually running.
    static func resolve(
        permissionReady: Bool,
        inputEngineRunning: Bool,
        paused: Bool
    ) -> AppRuntimeStatus {
        guard permissionReady else { return .permissionsNeeded }
        guard inputEngineRunning else { return .listeningFailed }
        return paused ? .paused : .running
    }
}
