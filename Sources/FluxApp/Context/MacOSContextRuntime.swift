// FluxApp.Context — macOS platform runtime for context history and Return.
//
// Bridges NSWorkspace frontmost-app notifications into the platform-neutral
// `ContextCoordinator` and resolves a `ContextSnapshot` into a real
// activation: activate the running instance (then best-effort raise its
// remembered window) or launch it through Launch Services. Every AppKit and
// ApplicationServices access is confined to this MainActor type, so the
// coordinator and history stay unit-testable without macOS permissions
// (design spec §7: platform boundaries are injected behind protocols).
//
// Window identity: the runtime owns one `MacOSWindowRegistry` that maps each
// process's focused AX window to an opaque identifier (design spec §4:
// bundle + process + focused window). The identifier is attached to the
// observed context, polled every `windowPollInterval` seconds while started
// so within-app window switches are captured even without an activation
// event. A window discovered for the already-current process enriches the
// current snapshot in place instead of shifting history, and a temporarily
// missing window never downgrades a known one.
//
// Notification safety: NSWorkspace posts its workspace notifications on the
// main thread, so selector-based NSObject observers reach the
// MainActor-isolated handlers without crossing Swift concurrency domains.
// The block-based observer API (`addObserver(forName:object:queue:using:)`)
// is deliberately avoided because it delivers on an arbitrary queue.

import AppKit
import ApplicationServices
import FluxCore

/// Owns the context coordinator and its macOS observation/activation layer.
///
/// Lifecycle: `start()` subscribes to the workspace activation and
/// termination notifications, records the current frontmost application
/// immediately, and starts the focused-window poll; `stop()` removes the
/// observers and invalidates the poll timer. Both methods are idempotent.
@MainActor
final class MacOSContextRuntime: NSObject, ContextTargetActivating {
    /// The platform-neutral coordinator, created lazily on first use so
    /// constructing the runtime touches no AppKit state. Its activator is
    /// this type, so a Return routes back through `activate(_:)`.
    private lazy var coordinator = ContextCoordinator(activator: self)

    /// The focused-window registry that maps AX windows to opaque
    /// identifiers. Owned here and purged as processes terminate.
    private let windowRegistry = MacOSWindowRegistry()

    /// The workspace notifications currently observed, used for removal.
    private var observedNotificationNames: [Notification.Name] = []

    /// The focused-window poll timer, running only while started.
    private var windowPollTimer: Timer?

    /// Poll cadence for capturing within-app focused-window switches
    /// (seconds). Bounded to the 0.4–0.5 second band requested by the
    /// window-restoration design.
    private static let windowPollInterval: TimeInterval = 0.45

    // MARK: - Coordinator state (read-only forwarding)

    /// The observed context history.
    var contextHistory: ContextHistory {
        coordinator.history
    }

    /// Whether a Return activation is currently awaiting its activator.
    var isReturnInFlight: Bool {
        coordinator.isReturnInFlight
    }

    // MARK: - Lifecycle

    /// Starts observing frontmost-app context. Idempotent.
    func start() {
        guard observedNotificationNames.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        observedNotificationNames = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        observeFrontmostApplication()
        startWindowPolling()
    }

    /// Stops observing frontmost-app context. Idempotent and safe to repeat.
    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for name in observedNotificationNames {
            center.removeObserver(self, name: name, object: nil)
        }
        observedNotificationNames.removeAll()
        stopWindowPolling()
    }

    /// Starts the focused-window poll. The timer is scheduled on the main
    /// run loop so its callback runs on the main thread;
    /// `MainActor.assumeIsolated` expresses that contract the same way the
    /// permission poll does in the app delegate. Idempotent.
    private func startWindowPolling() {
        guard windowPollTimer == nil else { return }
        let timer = Timer(
            timeInterval: Self.windowPollInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollFocusedWindow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        windowPollTimer = timer
    }

    /// Invalidates the focused-window poll. Idempotent.
    private func stopWindowPolling() {
        windowPollTimer?.invalidate()
        windowPollTimer = nil
    }

    /// Records the current frontmost application's context, capturing a
    /// within-app focused-window switch even without an activation event.
    private func pollFocusedWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        recordActivation(app)
    }

    // MARK: - ContextTargetActivating

    /// Activates the target application and reports whether activation
    /// actually happened.
    func activate(_ target: ContextSnapshot) async -> Bool {
        let bundleIdentifier = target.bundleIdentifier
        guard !bundleIdentifier.isEmpty else {
            NSLog("Flux: context activation rejected: empty bundle identifier")
            return false
        }
        guard bundleIdentifier != AppMetadata.current.bundleIdentifier else {
            NSLog("Flux: context activation rejected: own bundle identifier")
            return false
        }
        if let pid = target.processIdentifier,
           let pidApp = NSRunningApplication(processIdentifier: pid),
           !pidApp.isTerminated,
           pidApp.bundleIdentifier == bundleIdentifier {
            return activateRunningApplication(pidApp, target: target)
        }
        if let candidate = selectRunningApplication(for: bundleIdentifier) {
            return activateRunningApplication(candidate, target: target)
        }
        return await launchApplication(bundleIdentifier)
    }

    /// Activates the application with `bundleIdentifier`, treated as a
    /// bundle-only launch target (no process or window identity).
    func activateApplication(bundleIdentifier: String) async -> Bool {
        await activate(ContextSnapshot(bundleIdentifier: bundleIdentifier))
    }

    /// Returns to the previous context through the coordinator.
    @discardableResult
    func returnToPrevious() async -> Bool {
        await coordinator.returnToPrevious()
    }

    // MARK: - Observation

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else {
            return
        }
        recordActivation(app)
    }

    @objc private func applicationDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else {
            return
        }
        recordTermination(app)
    }

    /// Records the current frontmost application immediately on `start()`.
    private func observeFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        recordActivation(app)
    }

    /// Records a frontmost app unless it is Flux itself, lacks a bundle
    /// identifier, or is already terminated. Called from the activation
    /// notification, the initial capture on `start()`, and the poll timer.
    private func recordActivation(_ app: NSRunningApplication) {
        guard !app.isTerminated else { return }
        guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return
        }
        guard bundleIdentifier != AppMetadata.current.bundleIdentifier else { return }
        recordContext(bundleIdentifier: bundleIdentifier, processIdentifier: app.processIdentifier)
    }

    /// Records the context for `bundleIdentifier`/`processIdentifier`,
    /// attaching the focused-window identifier captured after the identity
    /// validation above.
    ///
    /// The same bundle/pid is treated specially so window discovery never
    /// pollutes the single-Caps history (design spec §4):
    /// - a window arriving for a current snapshot that has none enriches
    ///   `current` in place — an observation would push the window-less copy
    ///   into `previous`;
    /// - a temporarily nil capture for a current snapshot that already knows
    ///   its window preserves the known snapshot instead of downgrading it;
    /// - a genuinely different nonnil window is a real switch and becomes a
    ///   new observation, exactly like a different application.
    private func recordContext(bundleIdentifier: String, processIdentifier: Int32) {
        let windowIdentifier = windowRegistry.identifier(forFocusedWindowOf: processIdentifier)
        let snapshot = ContextSnapshot(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier,
            windowIdentifier: windowIdentifier
        )

        guard let current = coordinator.history.current,
              current.bundleIdentifier == bundleIdentifier,
              current.processIdentifier == processIdentifier else {
            coordinator.observe(snapshot)
            return
        }

        if let windowIdentifier {
            if current.windowIdentifier == nil {
                coordinator.enrichCurrentWindow(
                    identifier: windowIdentifier,
                    processIdentifier: processIdentifier
                )
            } else if current.windowIdentifier != windowIdentifier {
                coordinator.observe(snapshot)
            }
            // An equal window is an exact duplicate; observe ignores it.
        } else if current.windowIdentifier == nil {
            coordinator.observe(snapshot)
        }
        // Else: nil capture for a current snapshot that knows its window;
        // preserve the known window rather than downgrading it.
    }

    /// Marks a terminated process in the coordinator and purges its window
    /// registry entries.
    ///
    /// The PID is the authoritative key already stored in history, so the
    /// process is always marked terminated even when the termination
    /// notification carries no bundle metadata (and regardless of whether
    /// the terminated process is Flux itself).
    private func recordTermination(_ app: NSRunningApplication) {
        windowRegistry.purge(processIdentifier: app.processIdentifier)
        coordinator.markProcessTerminated(app.processIdentifier)
    }

    // MARK: - Activation resolution

    /// Selects a non-terminated running instance for the bundle: the active
    /// instance when present, otherwise the deterministic lowest pid.
    private func selectRunningApplication(
        for bundleIdentifier: String
    ) -> NSRunningApplication? {
        let candidates = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.bundleIdentifier == bundleIdentifier }
        guard !candidates.isEmpty else { return nil }
        return candidates.first { $0.isActive }
            ?? candidates.min { $0.processIdentifier < $1.processIdentifier }
    }

    /// Activates a running instance with empty options so macOS restores its
    /// normal last key window instead of forcing all windows, then
    /// best-effort raises the target's remembered window when the instance
    /// is the exact process that window belongs to.
    ///
    /// Application-level activation is the only success signal: a failed or
    /// skipped window restoration never downgrades it, and a successful AX
    /// raise never *proves* the application activated (the `activate`
    /// result does).
    private func activateRunningApplication(
        _ app: NSRunningApplication,
        target: ContextSnapshot
    ) -> Bool {
        guard app.activate(options: []) else {
            NSLog("Flux: context activation failed: activate returned false")
            return false
        }
        // A substituted instance (bundle fallback or relaunch) has a
        // different pid and must not apply another process's window.
        if app.processIdentifier == target.processIdentifier,
           let windowIdentifier = target.windowIdentifier {
            restoreWindowBestEffort(windowIdentifier, pid: app.processIdentifier)
        }
        return true
    }

    /// Best-effort restoration of one remembered window. Logs only constant
    /// state, the pid, and AX error codes (design spec §8); the result
    /// never affects the caller's activation success.
    private func restoreWindowBestEffort(_ identifier: String, pid: Int32) {
        switch windowRegistry.restore(identifier: identifier, for: pid) {
        case .restored:
            break
        case .notFound:
            NSLog("Flux: context window restore skipped: no window registered (pid %d)", pid)
        case .pidMismatch:
            NSLog("Flux: context window restore skipped: process mismatch (pid %d)", pid)
        case .staleRemoved:
            NSLog("Flux: context window restore skipped: stale window removed (pid %d)", pid)
        case .axFailed(let code):
            NSLog("Flux: context window restore failed (pid %d, ax %d)", pid, code)
        }
    }

    /// Launches the application via Launch Services with activation enabled.
    private func launchApplication(_ bundleIdentifier: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            NSLog("Flux: context activation failed: no application URL for bundle")
            return false
        }
        let app: NSRunningApplication
        do {
            app = try await openApplication(at: url)
        } catch {
            // Log only the error domain and code; the full error may embed
            // local paths or private metadata.
            let nsError = error as NSError
            NSLog(
                "Flux: context activation failed: open error (domain: %@, code: %ld)",
                nsError.domain,
                nsError.code
            )
            return false
        }
        guard !app.isTerminated else {
            NSLog("Flux: context activation failed: launched application is terminated")
            return false
        }
        return true
    }

    /// Opens an application and waits for its completion handler.
    ///
    /// The handler may run off the main thread, so it only resumes the
    /// continuation (exactly once, guaranteed by the completion contract and
    /// enforced by the checked continuation); the await returns the result
    /// back on the MainActor.
    private func openApplication(at url: URL) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: configuration
            ) { app, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let app {
                    continuation.resume(returning: app)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "FluxContextRuntime",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Open application returned no result"
                        ]
                    ))
                }
            }
        }
    }
}
