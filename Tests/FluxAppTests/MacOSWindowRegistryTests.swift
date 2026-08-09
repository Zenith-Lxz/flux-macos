import Testing
import ApplicationServices
@testable import FluxApp

// MARK: - Helpers

/// Fabricates an AXUIElement handle for a pid. CF-level operations
/// (CFHash/CFEqual) and AXUIElementGetPid work on these without
/// Accessibility trust; only attribute messaging needs the real permission,
/// so the registry's identifier/pid/eviction bookkeeping is fully testable.
private func fakeWindow(pid: Int32) -> AXUIElement {
    AXUIElementCreateApplication(pid)
}

@MainActor
private func makeRegistry(
    maxEntryCount: Int = 256,
    elementProvider: (@MainActor (Int32) -> AXUIElement?)? = nil,
    windowOperationProvider: (@MainActor (AXUIElement) -> [AXError])? = nil
) -> MacOSWindowRegistry {
    MacOSWindowRegistry(
        maxEntryCount: maxEntryCount,
        focusedWindowProvider: elementProvider,
        windowOperationProvider: windowOperationProvider
    )
}

// MARK: - Capture and identifier reuse

struct MacOSWindowRegistryCaptureTests {
    @Test @MainActor func sameWindowReusesIdentifier() {
        let registry = makeRegistry { pid in fakeWindow(pid: pid) }
        let first = registry.identifier(forFocusedWindowOf: 111)
        let second = registry.identifier(forFocusedWindowOf: 111)
        #expect(first != nil)
        #expect(first == second)
        #expect(registry.entryCount == 1)
    }

    @Test @MainActor func differentWindowGetsNewIdentifier() {
        let registry = makeRegistry { pid in fakeWindow(pid: pid) }
        let a = registry.identifier(forFocusedWindowOf: 111)
        let b = registry.identifier(forFocusedWindowOf: 222)
        #expect(a != nil)
        #expect(b != nil)
        #expect(a != b)
        #expect(registry.entryCount == 2)
    }

    @Test @MainActor func captureRejectsWindowNotOwnedByPid() {
        // The provider returns an element created for pid 111 even when
        // asked about pid 222; the registry must reject the mismatch.
        let registry = makeRegistry { _ in fakeWindow(pid: 111) }
        #expect(registry.identifier(forFocusedWindowOf: 222) == nil)
        #expect(registry.entryCount == 0)
        // The legitimate pid still captures normally.
        #expect(registry.identifier(forFocusedWindowOf: 111) != nil)
        #expect(registry.entryCount == 1)
    }

    @Test @MainActor func captureRejectsReuseAcrossPids() {
        let registry = makeRegistry { _ in fakeWindow(pid: 111) }
        guard let id = registry.identifier(forFocusedWindowOf: 111) else {
            Issue.record("expected capture to succeed")
            return
        }
        // The same window (pid 111) is claimed again under pid 222: reuse
        // must be refused and the original association kept intact.
        #expect(registry.identifier(forFocusedWindowOf: 222) == nil)
        #expect(registry.entryCount == 1)
        #expect(registry.restore(identifier: id, for: 111) != .notFound)
    }

    @Test @MainActor func opaqueIdentifiersAreStableStrings() {
        let registry = makeRegistry { pid in fakeWindow(pid: pid) }
        guard let id = registry.identifier(forFocusedWindowOf: 111) else {
            Issue.record("expected capture to succeed")
            return
        }
        #expect(id.hasPrefix("flux-window-"))
        #expect(registry.identifier(forFocusedWindowOf: 111) == id)
    }
}

// MARK: - Restoration

struct MacOSWindowRegistryRestoreTests {
    @Test @MainActor func restoreNotFoundForUnknownIdentifier() {
        let registry = makeRegistry()
        #expect(registry.restore(identifier: "flux-window-999", for: 111) == .notFound)
    }

    @Test @MainActor func restoreRejectsPidMismatchWithoutRemoving() {
        let registry = makeRegistry { pid in fakeWindow(pid: pid) }
        guard let id = registry.identifier(forFocusedWindowOf: 111) else {
            Issue.record("expected capture to succeed")
            return
        }
        #expect(registry.restore(identifier: id, for: 222) == .pidMismatch)
        #expect(registry.entryCount == 1)
    }

    @Test @MainActor func transientFailureKeepsEntryForLaterRetry() {
        let registry = makeRegistry(
            elementProvider: { pid in fakeWindow(pid: pid) },
            windowOperationProvider: { _ in
                [.cannotComplete, .cannotComplete, .cannotComplete]
            }
        )
        guard let id = registry.identifier(forFocusedWindowOf: 111) else {
            Issue.record("expected capture to succeed")
            return
        }
        #expect(
            registry.restore(identifier: id, for: 111)
                == .axFailed(AXError.cannotComplete.rawValue)
        )
        #expect(registry.entryCount == 1)
        #expect(
            registry.restore(identifier: id, for: 111)
                == .axFailed(AXError.cannotComplete.rawValue)
        )
    }

    @Test @MainActor func invalidElementFailureRemovesEntry() {
        let registry = makeRegistry(
            elementProvider: { pid in fakeWindow(pid: pid) },
            windowOperationProvider: { _ in
                [.invalidUIElement, .invalidUIElement, .invalidUIElement]
            }
        )
        guard let id = registry.identifier(forFocusedWindowOf: 111) else {
            Issue.record("expected capture to succeed")
            return
        }
        #expect(registry.restore(identifier: id, for: 111) == .staleRemoved)
        #expect(registry.entryCount == 0)
        #expect(registry.restore(identifier: id, for: 111) == .notFound)
    }

    @Test @MainActor func partialSuccessWinsOverAStaleOperationError() {
        let registry = makeRegistry(
            elementProvider: { pid in fakeWindow(pid: pid) },
            windowOperationProvider: { _ in
                [.invalidUIElement, .success, .attributeUnsupported]
            }
        )
        guard let id = registry.identifier(forFocusedWindowOf: 111) else {
            Issue.record("expected capture to succeed")
            return
        }
        #expect(registry.restore(identifier: id, for: 111) == .restored)
        #expect(registry.entryCount == 1)
    }

    @Test @MainActor func restoreResultNeverClaimsActivation() {
        // Compile-time/documentation contract: the enum has no case that
        // could be read as "the application activated"; the runtime treats
        // application activation independently.
        let registry = makeRegistry()
        let result = registry.restore(identifier: "missing", for: 1)
        #expect(result == .notFound || result == .pidMismatch)
    }
}

// MARK: - Bounding and eviction

struct MacOSWindowRegistryEvictionTests {
    @Test @MainActor func evictsOldestEntryWhenBounded() {
        let registry = makeRegistry(maxEntryCount: 2) { pid in fakeWindow(pid: pid) }
        guard let first = registry.identifier(forFocusedWindowOf: 111),
              registry.identifier(forFocusedWindowOf: 222) != nil else {
            Issue.record("expected captures to succeed")
            return
        }
        #expect(registry.entryCount == 2)

        // The third capture evicts the oldest (first) entry deterministically.
        guard let third = registry.identifier(forFocusedWindowOf: 333) else {
            Issue.record("expected capture to succeed")
            return
        }
        #expect(registry.entryCount == 2)

        // Presence checks reuse identifiers without touching AX attributes,
        // so they never perturb the registry's bookkeeping: the newest
        // window still maps to its original identifier…
        #expect(registry.identifier(forFocusedWindowOf: 333) == third)
        #expect(registry.entryCount == 2)

        // …and the evicted oldest window is gone: re-capturing it produces
        // a fresh identifier instead of the original one. If eviction had
        // picked any entry other than the oldest, `first` would still map.
        let recaptured = registry.identifier(forFocusedWindowOf: 111)
        #expect(recaptured != nil)
        #expect(recaptured != first)
        #expect(registry.entryCount == 2)
    }

    @Test @MainActor func purgeRemovesOnlyMatchingProcess() {
        let registry = makeRegistry { pid in fakeWindow(pid: pid) }
        guard let a = registry.identifier(forFocusedWindowOf: 111),
              let b = registry.identifier(forFocusedWindowOf: 222) else {
            Issue.record("expected captures to succeed")
            return
        }
        registry.purge(processIdentifier: 111)
        #expect(registry.entryCount == 1)
        #expect(registry.restore(identifier: a, for: 111) == .notFound)
        #expect(registry.restore(identifier: b, for: 222) != .notFound)
    }

    @Test @MainActor func defaultBoundIs256() {
        #expect(MacOSWindowRegistry.defaultMaxEntryCount == 256)
    }
}

// MARK: - Messaging timeout contract

struct MacOSWindowRegistryTimeoutTests {
    @Test func defaultTimeoutIsShort() {
        #expect(MacOSWindowRegistry.defaultMessagingTimeout == 0.15)
    }

    @Test func clampingRejectsNonPositiveAndNonFinite() {
        #expect(MacOSWindowRegistry.clampedMessagingTimeout(0.15) == 0.15)
        #expect(MacOSWindowRegistry.clampedMessagingTimeout(0.02) == 0.02)
        #expect(MacOSWindowRegistry.clampedMessagingTimeout(10) == 1.0)
        #expect(MacOSWindowRegistry.clampedMessagingTimeout(0) == 0.15)
        #expect(MacOSWindowRegistry.clampedMessagingTimeout(-3) == 0.15)
        #expect(MacOSWindowRegistry.clampedMessagingTimeout(.nan) == 0.15)
        #expect(MacOSWindowRegistry.clampedMessagingTimeout(.infinity) == 0.15)
    }
}
