// FluxApp.Context — macOS platform runtime for context history and Return.
//
// Bridges NSWorkspace frontmost-app notifications into the platform-neutral
// `ContextCoordinator` and resolves a `ContextSnapshot` into a real
// activation: activate the running instance or launch it through Launch
// Services. Every AppKit access is confined to this MainActor type, so the
// coordinator and history stay unit-testable without macOS permissions
// (design spec §7: platform boundaries are injected behind protocols).
//
// Notification safety: NSWorkspace posts its workspace notifications on the
// main thread, so selector-based NSObject observers reach the
// MainActor-isolated handlers without crossing Swift concurrency domains.
// The block-based observer API (`addObserver(forName:object:queue:using:)`)
// is deliberately avoided because it delivers on an arbitrary queue.

import AppKit
import FluxCore

/// Owns the context coordinator and its macOS observation/activation layer.
///
/// Lifecycle: `start()` subscribes to the workspace activation and
/// termination notifications, records the current frontmost application
/// immediately, and forwards both event kinds into the coordinator.
/// `stop()` removes the observers. Both methods are idempotent.
@MainActor
final class MacOSContextRuntime: NSObject, ContextTargetActivating {
    /// The platform-neutral coordinator, created lazily on first use so
    /// constructing the runtime touches no AppKit state. Its activator is
    /// this type, so a Return routes back through `activate(_:)`.
    private lazy var coordinator = ContextCoordinator(activator: self)

    /// The workspace notifications currently observed, used for removal.
    private var observedNotificationNames: [Notification.Name] = []

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
    }

    /// Stops observing frontmost-app context. Idempotent and safe to repeat.
    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for name in observedNotificationNames {
            center.removeObserver(self, name: name, object: nil)
        }
        observedNotificationNames.removeAll()
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
            return activateRunningApplication(pidApp)
        }
        if let candidate = selectRunningApplication(for: bundleIdentifier) {
            return activateRunningApplication(candidate)
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
    /// identifier, or is already terminated.
    private func recordActivation(_ app: NSRunningApplication) {
        guard !app.isTerminated else { return }
        guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return
        }
        guard bundleIdentifier != AppMetadata.current.bundleIdentifier else { return }
        coordinator.observe(
            ContextSnapshot(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: app.processIdentifier,
                windowIdentifier: nil
            )
        )
    }

    /// Marks a terminated process in the coordinator.
    ///
    /// The PID is the authoritative key already stored in history, so the
    /// process is always marked terminated even when the termination
    /// notification carries no bundle metadata (and regardless of whether
    /// the terminated process is Flux itself).
    private func recordTermination(_ app: NSRunningApplication) {
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
    /// normal last key window instead of forcing all windows.
    private func activateRunningApplication(_ app: NSRunningApplication) -> Bool {
        guard app.activate(options: []) else {
            NSLog("Flux: context activation failed: activate returned false")
            return false
        }
        return true
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
