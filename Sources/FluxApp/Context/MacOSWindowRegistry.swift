// FluxApp.Context — macOS focused-window registry.
//
// Maps the focused window of a running process to an opaque, stable
// identifier so context history can remember *which* window an application
// was using (design spec §4) without ever touching the window's contents.
//
// Privacy boundary (design spec §4, §8): the registry captures and retains
// only the focused-window AXUIElement *reference*. It never reads titles,
// values, descriptions, document contents, terminal/chat text, or browser
// data. Restoration sets the window's main/focused attributes and performs
// AXRaise — no text attribute is read or written.
//
// The registry is MainActor-isolated like the rest of the AppKit layer.
// Window capture is injectable so the identifier/eviction/pid bookkeeping is
// unit-testable with fabricated AXUIElement handles (CF-level operations and
// AXUIElementGetPid work without Accessibility trust; only attribute
// messaging needs the real permission).

import AppKit
import ApplicationServices

/// Outcome of a best-effort window restoration.
///
/// A `.restored` result means the AX window reference was found and at least
/// one main/focused/raise operation succeeded; it says nothing about whether
/// the application itself activated. The runtime treats application-level
/// activation as the Return success signal independently of this result.
enum WindowRestoreResult: Equatable {
    /// The window was found and at least one restore operation succeeded.
    case restored
    /// No entry exists for the identifier.
    case notFound
    /// The entry is stored under a different process; the request was
    /// rejected and the entry was left in place.
    case pidMismatch
    /// The element proved stale (its process is gone or AX rejected it as
    /// invalid); the entry was removed.
    case staleRemoved
    /// The window is valid but the AX operations failed; the entry is kept.
    /// The raw AXError code is attached for diagnostics only.
    case axFailed(Int32)
}

/// Bounded registry of focused-window references keyed by opaque
/// identifiers, one per AX window of a process.
@MainActor
final class MacOSWindowRegistry {
    // MARK: - Configuration

    /// Default maximum number of retained window entries. Bounded so a
    /// long-running Flux session cannot accumulate window references
    /// without limit.
    nonisolated static let defaultMaxEntryCount = 256

    /// Short AX messaging timeout applied before querying a focused window
    /// (seconds). Mirrors the focus controller's floor so a slow or
    /// hung application cannot stall the frontmost-app path.
    nonisolated static let defaultMessagingTimeout: Float = 0.15

    /// Floor for the per-application AX messaging timeout (seconds).
    nonisolated private static let minimumMessagingTimeout: Float = 0.01

    /// Ceiling for the per-application AX messaging timeout (seconds).
    nonisolated private static let maximumMessagingTimeout: Float = 1.0

    /// Normalizes a caller-supplied messaging timeout into a safe value.
    /// Non-finite (NaN, ±infinity), zero, and negative requests fall back
    /// to `defaultMessagingTimeout`; finite positive requests clamp into
    /// `[minimumMessagingTimeout, maximumMessagingTimeout]`.
    nonisolated static func clampedMessagingTimeout(_ requested: Float) -> Float {
        guard requested.isFinite, requested > 0 else {
            return defaultMessagingTimeout
        }
        return min(maximumMessagingTimeout, max(minimumMessagingTimeout, requested))
    }

    /// AX errors that prove the element no longer references a live window.
    ///
    /// `cannotComplete` is deliberately absent: it commonly means the target
    /// application timed out or is temporarily unresponsive, not that the
    /// window disappeared. `apiDisabled` likewise reflects Flux's permission
    /// state. Neither transient condition may purge a restorable entry.
    private static func isStaleAXError(_ error: AXError) -> Bool {
        error == .invalidUIElement
    }

    // MARK: - Storage

    private struct Entry {
        let pid: Int32
        let element: AXUIElement
        /// Monotonic insertion order used for deterministic eviction.
        let sequence: UInt64
    }

    private let maxEntryCount: Int
    private let focusedWindowProvider: @MainActor (Int32) -> AXUIElement?
    private let windowOperationProvider: @MainActor (AXUIElement) -> [AXError]

    /// identifier -> entry.
    private var entries: [String: Entry] = [:]
    /// CFHash -> [(identifier, element)] buckets. CFHash is not a perfect
    /// identity — distinct elements can collide on one hash — so each
    /// bucket keeps every same-hash element and reuse is confirmed with
    /// CFEqual, the same collision-safe pattern the focus controller uses.
    private var bucketsByHash: [UInt: [(identifier: String, element: AXUIElement)]] = [:]
    private var nextSequence: UInt64 = 0

    init(
        maxEntryCount: Int = MacOSWindowRegistry.defaultMaxEntryCount,
        messagingTimeout: Float = MacOSWindowRegistry.defaultMessagingTimeout,
        focusedWindowProvider: (@MainActor (Int32) -> AXUIElement?)? = nil,
        windowOperationProvider: (@MainActor (AXUIElement) -> [AXError])? = nil
    ) {
        self.maxEntryCount = max(1, maxEntryCount)
        let timeout = Self.clampedMessagingTimeout(messagingTimeout)
        self.focusedWindowProvider = focusedWindowProvider ?? { pid in
            Self.readFocusedWindow(for: pid, timeout: timeout)
        }
        self.windowOperationProvider = windowOperationProvider ?? { element in
            Self.performWindowOperations(on: element)
        }
    }

    // MARK: - Capture

    /// Returns the opaque identifier for the focused window of `pid`,
    /// capturing and retaining the window reference.
    ///
    /// Reuses the existing identifier when the same AX window (CFEqual,
    /// bucketed by CFHash) is captured again. Returns nil when no focused
    /// window is available or the window does not belong to `pid`.
    func identifier(forFocusedWindowOf pid: Int32) -> String? {
        guard let window = focusedWindowProvider(pid) else { return nil }
        return register(window, for: pid)
    }

    /// Registers a focused-window reference under `pid`.
    ///
    /// Rejects (returns nil) any window whose AX element does not belong to
    /// `pid` — a mismatch would associate another process's window with this
    /// pid. On success the identifier is opaque and stable for the window.
    private func register(_ window: AXUIElement, for pid: Int32) -> String? {
        var windowPid: pid_t = 0
        guard AXUIElementGetPid(window, &windowPid) == .success,
              windowPid == pid else {
            return nil
        }

        let hash = UInt(CFHash(window))
        if let bucket = bucketsByHash[hash] {
            for (identifier, element) in bucket where CFEqual(element, window) {
                // Same window. A stored pid mismatch means the association is
                // broken; refuse to reuse it for this pid.
                guard entries[identifier]?.pid == pid else { return nil }
                return identifier
            }
        }

        let sequence = nextSequence
        nextSequence += 1
        let identifier = "flux-window-\(sequence)"
        entries[identifier] = Entry(pid: pid, element: window, sequence: sequence)
        var bucket = bucketsByHash[hash] ?? []
        bucket.append((identifier, window))
        bucketsByHash[hash] = bucket
        evictOldestIfNeeded()
        return identifier
    }

    // MARK: - Restoration

    /// Restores the window identified by `identifier` for process `pid`.
    ///
    /// Best effort: sets AXMain and AXFocused and performs AXRaise. The
    /// result reports window-level state only — a `.restored` result never
    /// means the application was activated. Stale or invalid entries are
    /// removed; mismatched pids are rejected without mutation.
    @discardableResult
    func restore(identifier: String, for pid: Int32) -> WindowRestoreResult {
        guard let entry = entries[identifier] else { return .notFound }
        guard entry.pid == pid else { return .pidMismatch }

        var elementPid: pid_t = 0
        guard AXUIElementGetPid(entry.element, &elementPid) == .success,
              elementPid == pid else {
            removeEntry(identifier: identifier)
            return .staleRemoved
        }

        let outcome = raiseWindow(entry.element)
        // Success first: any operation that worked proves the window is
        // alive, so the entry survives even when another operation rejected
        // the attribute (some apps refuse AXMain/AXFocused on odd windows).
        if outcome.succeeded {
            return .restored
        }
        if outcome.stale {
            removeEntry(identifier: identifier)
            return .staleRemoved
        }
        return .axFailed(outcome.firstError?.rawValue ?? -1)
    }

    /// Applies main/focused/raise to `element`, reporting whether anything
    /// succeeded, whether an error marked the element stale, and the first
    /// non-stale error for diagnostics.
    private func raiseWindow(_ element: AXUIElement) -> (
        succeeded: Bool,
        stale: Bool,
        firstError: AXError?
    ) {
        var succeeded = false
        var stale = false
        var firstError: AXError?

        func record(_ error: AXError) {
            switch error {
            case .success:
                succeeded = true
            case let staleError where Self.isStaleAXError(staleError):
                stale = true
            default:
                if firstError == nil { firstError = error }
            }
        }

        for error in windowOperationProvider(element) {
            record(error)
        }
        return (succeeded, stale, firstError)
    }

    /// Performs the three real Accessibility operations used to make a
    /// remembered window current. Kept behind an injected provider so tests
    /// can verify stale/transient classification without depending on the
    /// host's Accessibility permission state.
    private static func performWindowOperations(on element: AXUIElement) -> [AXError] {
        [
            AXUIElementSetAttributeValue(
                element,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            ),
            AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            ),
            AXUIElementPerformAction(element, kAXRaiseAction as CFString),
        ]
    }

    // MARK: - Lifecycle

    /// Removes every entry associated with a terminated process.
    func purge(processIdentifier pid: Int32) {
        let matching = entries.keys.filter { entries[$0]?.pid == pid }
        for identifier in matching {
            removeEntry(identifier: identifier)
        }
    }

    /// The number of retained window entries (visible for tests).
    var entryCount: Int {
        entries.count
    }

    /// Removes the oldest entry while the registry exceeds its bound.
    /// Deterministic: the entry with the smallest insertion sequence wins,
    /// so eviction order never depends on dictionary iteration order.
    private func evictOldestIfNeeded() {
        guard entries.count > maxEntryCount,
              let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence }) else {
            return
        }
        removeEntry(identifier: oldest.key)
    }

    private func removeEntry(identifier: String) {
        guard let entry = entries.removeValue(forKey: identifier) else { return }
        let hash = UInt(CFHash(entry.element))
        if var bucket = bucketsByHash[hash] {
            bucket.removeAll { $0.identifier == identifier }
            if bucket.isEmpty {
                bucketsByHash.removeValue(forKey: hash)
            } else {
                bucketsByHash[hash] = bucket
            }
        }
    }

    // MARK: - AX capture

    /// Copies the focused window reference of `pid`'s application element.
    ///
    /// Reads only `kAXFocusedWindowAttribute`; no text attributes. Applies
    /// the short messaging timeout first so an unresponsive application
    /// cannot stall the caller.
    private static func readFocusedWindow(
        for pid: Int32,
        timeout: Float
    ) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(application, timeout) == .success else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // Parenthesized forced cast: the compiler treats a bare `as!` to a
        // CF-bridged type as an unnecessary optional cast and warns.
        return (value as! AXUIElement)
    }
}
