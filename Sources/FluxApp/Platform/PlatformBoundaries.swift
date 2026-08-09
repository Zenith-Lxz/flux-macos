@preconcurrency import CoreGraphics
import CoreFoundation
import FluxCore

/// Creates and owns the CoreGraphics event-tap plumbing. The implementation
/// is stateless; nonisolated methods let the input engine use the same adapter
/// from its defensive deinitializer as from its main-actor lifecycle.
protocol EventTapProviding: AnyObject, Sendable {
    nonisolated func createEventTap(
        callback: CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer?
    ) -> CFMachPort?
    nonisolated func createRunLoopSource(for tap: CFMachPort) -> CFRunLoopSource?
    nonisolated func addToMainRunLoop(_ source: CFRunLoopSource)
    nonisolated func removeFromMainRunLoop(_ source: CFRunLoopSource)
    nonisolated func setEnabled(_ tap: CFMachPort, _ enabled: Bool)
    nonisolated func isEnabled(_ tap: CFMachPort) -> Bool
    nonisolated func invalidate(_ tap: CFMachPort)
}

final class MacOSEventTapProvider: EventTapProviding {
    nonisolated func createEventTap(
        callback: CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer?
    ) -> CFMachPort? {
        let eventsOfInterest: CGEventMask =
            (UInt64(1) << UInt64(CGEventType.keyDown.rawValue))
            | (UInt64(1) << UInt64(CGEventType.keyUp.rawValue))
            | (UInt64(1) << UInt64(CGEventType.flagsChanged.rawValue))
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: callback,
            userInfo: userInfo
        )
    }

    nonisolated func createRunLoopSource(for tap: CFMachPort) -> CFRunLoopSource? {
        CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    }

    nonisolated func addToMainRunLoop(_ source: CFRunLoopSource) {
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    nonisolated func removeFromMainRunLoop(_ source: CFRunLoopSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }

    nonisolated func setEnabled(_ tap: CFMachPort, _ enabled: Bool) {
        CGEvent.tapEnable(tap: tap, enable: enabled)
    }

    nonisolated func isEnabled(_ tap: CFMachPort) -> Bool {
        CGEvent.tapIsEnabled(tap: tap)
    }

    nonisolated func invalidate(_ tap: CFMachPort) {
        CFMachPortInvalidate(tap)
    }
}

/// Sends already-marked synthetic events. Tests inject a recorder so pointer
/// and keyboard output can be verified without posting into the user's input
/// stream.
@MainActor
protocol EventPosting: AnyObject {
    func post(_ event: CGEvent)
}

@MainActor
final class MacOSEventPoster: EventPosting {
    func post(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }
}

/// Accessibility focus-tree boundary used by the input engine.
@MainActor
protocol AXTreeReading: AnyObject {
    @discardableResult
    func moveFocus(_ direction: Direction) -> Bool
}

/// Supplies the observed frontmost application identity to key routing.
@MainActor
protocol FrontmostAppProviding: AnyObject {
    var frontmostBundleIdentifier: String? { get }
}
