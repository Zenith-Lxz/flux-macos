// FluxApp.Pointer — macOS Accessibility pointer snapper.
//
// Bounded Accessibility probe for design spec §6 pointer snapping: after a
// non-repeat pointer move, the pointer controller asks for a nearby
// interactive AX element and adopts its frame center when one is found.
// The probe is deliberately conservative:
//
// - exactly one AXUIElementCopyElementAtPosition at the proposed target
//   (no screen-wide tree walk, no grid of many queries);
// - the hit element plus at most 3 ancestors;
// - a short ~0.15s process-global AX messaging timeout before hit testing
//   and attribute reads, so an unresponsive app cannot stall indefinitely;
// - reads only role, parent, position, size, hidden, enabled, supported
//   action names, and pid — never title/value/description/content
//   (design spec §4, §8 privacy boundary);
// - a candidate is eligible only when it is not hidden, is enabled (a
//   missing AXEnabled counts as enabled), has a finite positive frame, and
//   either has a standard interactive role or supports an activation action;
// - acceptance only within a conservative 32pt radius of the geometric
//   target, nearest center first with a deterministic depth tie-break.
//
// Every permission/timeout/read failure returns nil silently, so expected
// misses never flood logs and the controller keeps the geometric point.
// The snapper requests no permissions, performs no AX work at construction (the
// system-wide element is created lazily), and never launches anything.

import ApplicationServices
import CoreGraphics
import FluxCore
import Foundation

/// The snap boundary used by the pointer controller: given the proposed
/// geometric target of a pointer move, return the snap destination or nil
/// to keep the geometric point.
@MainActor
protocol PointerSnapping: AnyObject {
    func snapPoint(for target: CGPoint) -> CGPoint?
}

/// Bounded Accessibility pointer snapper (design spec §6).
@MainActor
final class MacOSPointerSnapper: PointerSnapping {
    // MARK: - Configuration

    /// Floor for the per-application AX messaging timeout (seconds).
    private static let minimumMessagingTimeout: Float = 0.01

    /// Ceiling for the per-application AX messaging timeout (seconds).
    private static let maximumMessagingTimeout: Float = 1.0

    /// Default AX messaging timeout (seconds), also the fallback for NaN,
    /// infinity, zero, or negative caller-supplied values.
    private static let defaultMessagingTimeout: Float = 0.15

    /// Per-application AX messaging timeout in seconds.
    private let messagingTimeout: Float

    /// Snap acceptance policy (design spec §6: 32pt radius, 3 ancestors).
    private let policy: PointerSnapPolicy

    /// The system-wide AX element. Created lazily on the first snap so
    /// constructing the snapper — and therefore the pointer controller —
    /// does no AX work and stays permission-free (design spec §7).
    private lazy var systemWideElement = AXUIElementCreateSystemWide()

    /// Set after a fatal/transport AX error so the current bounded probe
    /// stops immediately instead of paying the timeout again for every
    /// remaining attribute and ancestor.
    private var probeAborted = false

    init(messagingTimeout: Float = 0.15, policy: PointerSnapPolicy = .init()) {
        self.messagingTimeout = Self.clampedMessagingTimeout(messagingTimeout)
        self.policy = policy
    }

    /// Normalizes a caller-supplied messaging timeout into a safe value.
    /// Non-finite (NaN, ±infinity), zero, and negative requests fall back
    /// to `defaultMessagingTimeout`; finite positive requests clamp into
    /// `[minimumMessagingTimeout, maximumMessagingTimeout]`.
    private static func clampedMessagingTimeout(_ requested: Float) -> Float {
        guard requested.isFinite, requested > 0 else {
            return defaultMessagingTimeout
        }
        return min(maximumMessagingTimeout, max(minimumMessagingTimeout, requested))
    }

    // MARK: - Public API

    /// Returns the center of the best nearby eligible AX element in Quartz
    /// global screen coordinates (top-left origin, +Y down), or nil when no
    /// element is found, permission is missing, a read times out or fails,
    /// or no eligible element is within the acceptance radius. Every nil
    /// return is fail-closed: the caller posts the original geometric
    /// point, so pointer output is never blocked.
    func snapPoint(for target: CGPoint) -> CGPoint? {
        guard target.x.isFinite, target.y.isFinite else { return nil }
        probeAborted = false

        // Bound the hit query itself: the system-wide element's default
        // messaging timeout is large, so pin it to the same short value
        // before the one position query.
        let systemWide = systemWideElement
        let systemTimeoutError = AXUIElementSetMessagingTimeout(
            systemWide, messagingTimeout)
        guard systemTimeoutError == .success else { return nil }

        var hitElement: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(
            systemWide, Float(target.x), Float(target.y), &hitElement)
        guard hitError == .success, let hitElement else { return nil }

        // Validate the hit element's owning process. The system-wide timeout
        // above is process-global for this Accessibility client and already
        // bounds the attribute reads below; setting a timeout on a separate
        // application element would affect only that object, not its child
        // elements (AXUIElementSetMessagingTimeout contract).
        var pid: pid_t = 0
        let pidError = AXUIElementGetPid(hitElement, &pid)
        guard pidError == .success, pid > 0 else { return nil }

        // The hit element plus up to maxDepth ancestors. The chain stops
        // naturally at the application element and is additionally bounded
        // by the depth loop, so a malformed cyclic parent chain cannot run
        // forever.
        var candidates: [PointerSnapCandidate] = []
        var element: AXUIElement? = hitElement
        var depth = 0
        while let current = element, depth <= policy.maxDepth {
            let role = role(of: current)
            guard !probeAborted else { return nil }
            if let candidate = candidate(for: current, depth: depth, role: role) {
                candidates.append(candidate)
            }
            guard !probeAborted else { return nil }
            if role == kAXApplicationRole { break }
            element = parent(of: current)
            guard !probeAborted else { return nil }
            depth += 1
        }

        guard let winner = PointerSnapSelector().select(
            from: candidates,
            target: PointerSnapPoint(x: target.x, y: target.y),
            policy: policy
        ) else { return nil }
        return CGPoint(x: winner.frame.midX, y: winner.frame.midY)
    }

    // MARK: - AX attribute helpers

    /// Copies one attribute value; nil on any error.
    private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else {
            recordProbeError(error)
            return nil
        }
        return value
    }

    /// Transport/permission/invalid-element errors make further reads in
    /// the same probe futile. Missing or unsupported optional attributes do
    /// not abort because eligibility deliberately tolerates their absence.
    private func recordProbeError(_ error: AXError) {
        switch error {
        case .cannotComplete, .apiDisabled, .invalidUIElement, .notImplemented, .failure:
            probeAborted = true
        default:
            break
        }
    }

    /// The element's AXParent as an AX element, or nil when missing.
    private func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(element, kAXParentAttribute as CFString) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // Parenthesized forced cast: the compiler treats a bare `as!` to a
        // CF-bridged type as an unnecessary optional cast and warns.
        return (value as! AXUIElement)
    }

    /// The element's AXRole string.
    private func role(of element: AXUIElement) -> String? {
        copyAttribute(element, kAXRoleAttribute as CFString) as? String
    }

    /// The element's AXPosition as a CGPoint.
    private func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// The element's AXSize as a CGSize.
    private func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Copies a Boolean attribute (AXHidden, AXEnabled). Missing values
    /// return nil and are treated as absent, not as false. CFBoolean and
    /// CFNumber both bridge to NSNumber, so one read covers both shapes.
    private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// The element's supported action names as a set; empty on any error.
    private func actionNames(of element: AXUIElement) -> Set<String> {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        guard error == .success, let names else {
            recordProbeError(error)
            return []
        }
        return Set((names as? [String]) ?? [])
    }

    /// Builds an eligible snap candidate for one chain element, reading
    /// only the whitelisted attributes. Returns nil when the element is
    /// hidden, disabled, has no valid frame, or is neither a standard
    /// interactive role nor an activation-action element.
    private func candidate(
        for element: AXUIElement,
        depth: Int,
        role: String?
    ) -> PointerSnapCandidate? {
        let hidden = boolAttribute(element, kAXHiddenAttribute as CFString)
        guard !probeAborted else { return nil }
        let enabled = boolAttribute(element, kAXEnabledAttribute as CFString)
        guard !probeAborted else { return nil }
        guard let position = pointAttribute(element, kAXPositionAttribute as CFString) else {
            return nil
        }
        guard !probeAborted else { return nil }
        guard let size = sizeAttribute(element, kAXSizeAttribute as CFString) else { return nil }
        guard !probeAborted else { return nil }
        let frame = PointerSnapFrame(
            x: position.x,
            y: position.y,
            width: size.width,
            height: size.height
        )
        // Action names are read only for elements whose role is not already
        // a standard interactive role, keeping the per-element read count
        // bounded.
        let actions: Set<String>
        if let role, PointerSnapEligibility.standardInteractiveRoles.contains(role) {
            actions = []
        } else {
            actions = actionNames(of: element)
        }
        guard !probeAborted else { return nil }
        guard PointerSnapEligibility.isEligible(
            hidden: hidden,
            enabled: enabled,
            role: role,
            supportedActions: actions,
            frame: frame
        ) else { return nil }
        return PointerSnapCandidate(
            identifier: "\(depth)",
            frame: frame,
            depth: depth
        )
    }
}
