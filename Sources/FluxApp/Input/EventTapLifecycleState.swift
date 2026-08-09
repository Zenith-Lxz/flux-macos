/// Permission-free lifecycle state for the suppressing event tap.
///
/// CoreGraphics reports tap enablement separately from the enable request.
/// This state machine turns that observed result into an explicit fail-closed
/// transition that can be unit tested without installing a real event tap.
struct EventTapLifecycleState: Sendable, Equatable {
    enum RecoveryOutcome: Sendable, Equatable {
        case ignored
        case recovered
        case failedClosed
    }

    private(set) var isRunning = false

    mutating func didStart() {
        isRunning = true
    }

    mutating func didStop() {
        isRunning = false
    }

    /// Reconciles one disabled-tap recovery attempt. A missing tap or a tap
    /// that remains disabled immediately clears the running state so HID Caps
    /// callbacks become inert before platform resources are torn down.
    mutating func reconcileRecovery(
        hasTap: Bool,
        isEnabledAfterAttempt: Bool
    ) -> RecoveryOutcome {
        guard isRunning else { return .ignored }
        guard hasTap, isEnabledAfterAttempt else {
            isRunning = false
            return .failedClosed
        }
        return .recovered
    }
}
