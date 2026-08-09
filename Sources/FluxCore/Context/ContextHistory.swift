// FluxCore.Context — platform-neutral context history state machine.
//
// Tracks the frontmost application context and the previous one so a single
// Caps press can swap back and forth (design spec §3.1, §4). The state
// machine depends only on Swift value types (String, Int32?, String?) and
// carries no AppKit/CoreGraphics or Accessibility types, so context history
// stays unit-testable without macOS permissions (design spec §7: platform
// boundaries are injected behind protocols).

/// One observed application context.
///
/// The minimal runtime context is `bundle identifier + process identifier +
/// focused window AX reference + timestamp` (design spec §4). The timestamp
/// belongs to the platform observation layer, so this model keeps the three
/// identity fields Flux needs to compare contexts, return to a window, and
/// relaunch an application.
public struct ContextSnapshot: Sendable, Equatable, Hashable {
    /// The application's bundle identifier, for example `com.google.Chrome`.
    public let bundleIdentifier: String
    /// The running process identifier; nil when only a launch target remains.
    public let processIdentifier: Int32?
    /// The focused window identifier; nil when no window is known.
    public let windowIdentifier: String?

    public init(
        bundleIdentifier: String,
        processIdentifier: Int32? = nil,
        windowIdentifier: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier
    }
}

/// Deterministic two-slot context history for single-Caps Return.
///
/// `current` is the frontmost application context and `previous` is the
/// context Flux returns to. `commitReturn` performs a real swap instead of
/// reopening the second-to-last application, so repeated Caps presses
/// toggle A ↔ B stably (design spec §4).
public struct ContextHistory: Sendable {
    /// The current frontmost context, if any.
    public private(set) var current: ContextSnapshot?
    /// The context a Return would swap to, if any.
    public private(set) var previous: ContextSnapshot?

    public init(initial: ContextSnapshot? = nil) {
        current = initial
        previous = nil
    }

    /// Records an observed context.
    ///
    /// Exact duplicates of `current` are ignored — for example the
    /// activation event Flux receives after a committed return must not
    /// shift history. Every other observation, including the same
    /// application with a different window or process, becomes the new
    /// current context and pushes the old current into `previous`
    /// (design spec §4).
    public mutating func observe(_ snapshot: ContextSnapshot) {
        guard snapshot != current else { return }
        previous = current
        current = snapshot
    }

    /// The context a Return would swap to, without mutating history.
    public var returnCandidate: ContextSnapshot? {
        previous
    }

    /// Swaps `current` and `previous` when `candidate` is still exactly the
    /// previous context.
    ///
    /// Returns true only for an up-to-date candidate; a stale candidate or
    /// a missing previous context fails transactionally with no mutation.
    /// On success the swap makes the returned context current and the old
    /// current previous, so repeated returns toggle A ↔ B (design spec §4).
    @discardableResult
    public mutating func commitReturn(to candidate: ContextSnapshot) -> Bool {
        guard candidate == previous else { return false }
        let returned = previous
        previous = current
        current = returned
        return true
    }

    /// Clears the live identity of a terminated process.
    ///
    /// Every stored snapshot whose `processIdentifier` matches `pid` keeps
    /// its bundle identifier but drops its process and window identity, so
    /// the application can later be relaunched and re-observed from a fresh
    /// process (design spec §4: bundle → running instance → launch). All
    /// other snapshots are unchanged.
    public mutating func markProcessTerminated(_ pid: Int32) {
        if current?.processIdentifier == pid {
            current = current?.clearingLiveIdentity()
        }
        if previous?.processIdentifier == pid {
            previous = previous?.clearingLiveIdentity()
        }
    }

    /// Resets history to the given initial context (or to empty).
    public mutating func reset(initial: ContextSnapshot? = nil) {
        current = initial
        previous = nil
    }
}

private extension ContextSnapshot {
    /// Returns a copy that keeps the bundle identifier but drops the process
    /// and window identity, used after the process terminated.
    func clearingLiveIdentity() -> ContextSnapshot {
        ContextSnapshot(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: nil,
            windowIdentifier: nil
        )
    }
}
