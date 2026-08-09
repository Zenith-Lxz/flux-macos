// FluxApp.Focus — macOS Accessibility focus controller.
//
// Bridges one spatial focus move (design spec §5) into the real
// Accessibility tree of the frontmost application: reads only geometry and
// structural attributes from the focused window's descendants, scores the
// candidates with the platform-neutral SpatialNavigator, and applies the
// winner's AXFocused attribute, then briefly highlights the winner with a
// transient, non-activating focus ring around its raw AX frame (design spec
// §5). The controller requests no permissions and touches the window server
// only after a successful move; when Accessibility is unavailable it fails
// closed and logs only constant state plus AXError codes (design spec §8:
// diagnostic logs never carry private content).
//
// Privacy boundary (design spec §4, §8): this controller reads only role,
// children, position, size, hidden, enabled, supported action names, and
// AXFocused settability. It never reads titles, values, descriptions,
// document contents, terminal/chat text, or browser data.

import AppKit
import ApplicationServices
import FluxCore

/// Moves the Accessibility focus of the frontmost application spatially.
///
/// Each `moveFocus(_:)` call performs a fresh, bounded walk of the focused
/// window's descendants (no cache), so a stale tree can never leak between
/// actions; tree and window changes are inherently picked up on the next
/// move.
@MainActor
final class MacOSFocusController: AXTreeReading {
    // MARK: - Configuration

    /// Floor for the per-application AX messaging timeout (seconds). The
    /// global input path must never inherit an unbounded/infinite timeout.
    private static let minimumMessagingTimeout: Float = 0.01

    /// Ceiling for the per-application AX messaging timeout (seconds).
    private static let maximumMessagingTimeout: Float = 1.0

    /// Default AX messaging timeout (seconds), also the fallback for NaN,
    /// infinity, zero, or negative caller-supplied values.
    private static let defaultMessagingTimeout: Float = 0.15

    /// Roles treated as interactive candidates (design spec §5). String
    /// literals cover roles that have no SDK constant (AXLink, AXListItem,
    /// AXTabButton) or that some apps expose under their raw role.
    private static let standardInteractiveRoles: Set<String> = [
        kAXButtonRole,
        "AXLink",
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXCheckBoxRole,
        kAXRadioButtonRole,
        kAXMenuItemRole,
        kAXMenuButtonRole,
        kAXMenuBarItemRole,
        kAXPopUpButtonRole,
        kAXComboBoxRole,
        kAXSliderRole,
        kAXRowRole,
        kAXCellRole,
        "AXListItem",
        kAXTabGroupRole,
        "AXTabButton",
    ]

    /// Roles that define a region: the nearest such ancestor clusters
    /// spatial navigation before leaving it (design spec §5).
    private static let regionRoles: Set<String> = [
        kAXGroupRole,
        kAXSplitGroupRole,
        kAXToolbarRole,
        kAXScrollAreaRole,
        kAXListRole,
        kAXTableRole,
        kAXOutlineRole,
        kAXBrowserRole,
    ]

    /// Hard cap on visited elements per traversal.
    private let maxElementCount: Int

    /// Per-application AX messaging timeout in seconds.
    private let messagingTimeout: Float

    /// Drives the transient focus ring; the panel is created lazily on the
    /// first successful move, so constructing the controller never touches
    /// the window server (permission-free tests stay side-effect free).
    private let focusRingPresenter = FocusRingPresenter()

    init(maxElementCount: Int = 2_000, messagingTimeout: Float = 0.15) {
        // Clamp to at least one element; the timeout is normalized by
        // clampedMessagingTimeout so the global input can never inherit an
        // infinite or nonpositive timeout.
        self.maxElementCount = max(1, maxElementCount)
        self.messagingTimeout = Self.clampedMessagingTimeout(messagingTimeout)
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

    /// Moves the Accessibility focus of the frontmost application by one
    /// spatial step. Returns true only when a target was chosen and its
    /// AXFocused attribute was set successfully.
    @discardableResult
    func moveFocus(_ direction: Direction) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            NSLog("Flux: focus move unavailable: no frontmost application")
            return false
        }
        guard !frontmost.isTerminated else {
            NSLog("Flux: focus move unavailable: frontmost application is terminated")
            return false
        }
        guard frontmost.bundleIdentifier != AppMetadata.current.bundleIdentifier else {
            NSLog("Flux: focus move unavailable: frontmost application is Flux")
            return false
        }

        let pid = frontmost.processIdentifier
        // Apple documents one special case: setting the timeout on the
        // system-wide element configures it globally for this process. That
        // bounds the application, window, and descendant reads below; using
        // an ordinary element would affect only that exact object.
        let systemWide = AXUIElementCreateSystemWide()
        let timeoutError = AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        guard timeoutError == .success else {
            NSLog("Flux: focus move unavailable: global messaging timeout not applied (ax %d)", timeoutError.rawValue)
            return false
        }
        let application = AXUIElementCreateApplication(pid)

        // Source frames: the focused UI element when valid, otherwise the
        // focused window frame; neither valid means no navigation.
        guard let window = elementAttribute(application, kAXFocusedWindowAttribute as CFString) else {
            NSLog("Flux: focus move unavailable: no focused window")
            return false
        }
        let focusedElement = elementAttribute(application, kAXFocusedUIElementAttribute as CFString)
        let windowFrame = frame(of: window)
        guard let sourceFrame = focusedElement.flatMap({ frame(of: $0) }) ?? windowFrame else {
            NSLog("Flux: focus move unavailable: no valid source frame")
            return false
        }

        // Fresh bounded DFS in AXChildren order over the focused window's
        // descendants. Every visited node gets a deterministic traversal
        // index; candidates are tagged with the region of their nearest
        // region ancestor, and the focused element (when eligible) is
        // remembered as the exact source.
        var candidates: [SpatialCandidate] = []
        var elementsByID: [String: AXUIElement] = [:]
        var rawFramesByID: [String: CGRect] = [:]
        var focusedCandidate: SpatialCandidate?
        var visitedByHash: [UInt: [AXUIElement]] = [:]
        var index = 0
        var stack: [(element: AXUIElement, inheritedRegion: String?)] = []
        if let children = children(of: window) {
            for child in children.reversed() {
                stack.append((child, nil))
            }
        }

        while let (element, inheritedRegion) = stack.popLast(), index < maxElementCount {
            // Cycle guard: CFHash is not a perfect identity — distinct
            // elements can collide on the same hash — so a Set<UInt> could
            // drop a real element. Each hash is a bucket of elements; an
            // element counts as visited only when a same-hash bucket member
            // is CFEqual to it, and is appended to the bucket otherwise.
            // Traversal stays bounded by maxElementCount below.
            let hash = UInt(CFHash(element))
            var bucket = visitedByHash[hash] ?? []
            if bucket.contains(where: { CFEqual($0, element) }) { continue }
            bucket.append(element)
            visitedByHash[hash] = bucket
            let traversalIndex = index
            index += 1

            let role = role(of: element)
            let subtreeRegion: String?
            if let role, Self.regionRoles.contains(role) {
                subtreeRegion = "\(traversalIndex)-\(role)"
            } else {
                subtreeRegion = inheritedRegion
            }

            if let children = children(of: element) {
                let remaining = maxElementCount - index
                if remaining > 0 {
                    for child in children.prefix(remaining).reversed() {
                        stack.append((child, subtreeRegion))
                    }
                }
            }

            guard isEligible(element, role: role),
                  let rawFrame = rawFrame(of: element),
                  let elementFrame = spatialFrame(fromRawAXFrame: rawFrame) else { continue }

            let identifier = "\(pid)-\(traversalIndex)"
            let candidate = SpatialCandidate(
                identifier: identifier,
                frame: elementFrame,
                // The computed subtreeRegion, not the inherited one, so a
                // region element itself belongs to its own deterministic
                // region; its descendants continue inheriting that region.
                regionIdentifier: subtreeRegion,
                traversalIndex: traversalIndex
            )
            candidates.append(candidate)
            elementsByID[identifier] = element
            // Raw AX frame kept only for this move: the ring presenter
            // converts it immediately and never retains it.
            rawFramesByID[identifier] = rawFrame
            if let focusedElement, CFEqual(element, focusedElement) {
                focusedCandidate = candidate
            }
        }

        // Source: the eligible focused candidate when it was encountered,
        // otherwise a synthetic source from the focused element/window frame
        // with no region.
        let source: SpatialCandidate
        if let focusedCandidate {
            source = focusedCandidate
        } else {
            source = SpatialCandidate(
                identifier: "\(pid)-source",
                frame: sourceFrame,
                regionIdentifier: nil,
                traversalIndex: -1
            )
        }

        guard let target = SpatialNavigator().select(
            from: source,
            candidates: candidates,
            direction: direction
        ), let targetElement = elementsByID[target.identifier] else {
            NSLog("Flux: focus move failed: no candidate in direction")
            return false
        }

        let error = AXUIElementSetAttributeValue(
            targetElement,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard error == .success else {
            NSLog("Flux: focus move failed: set focused attribute error (ax %d)", error.rawValue)
            return false
        }
        // The ring appears only after the AX focus move succeeded (design
        // spec §5); invalid geometry fails closed without showing.
        if let rawFrame = rawFramesByID[target.identifier] {
            focusRingPresenter.show(axFrame: rawFrame)
        }
        return true
    }

    // MARK: - AX attribute helpers

    /// Copies one attribute value; nil on any error.
    private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else { return nil }
        return value
    }

    /// Copies an attribute that must itself be an AX element.
    private func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // Parenthesized forced cast: the compiler treats a bare `as!` to a
        // CF-bridged type as an unnecessary optional cast and warns.
        return (value as! AXUIElement)
    }

    /// Copies a Boolean attribute (AXHidden, AXEnabled). Missing values
    /// return nil and are treated as absent, not as false. CFBoolean and
    /// CFNumber both bridge to NSNumber, so one read covers both shapes.
    private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// The element's AXRole string.
    private func role(of element: AXUIElement) -> String? {
        copyAttribute(element, kAXRoleAttribute as CFString) as? String
    }

    /// The element's AXChildren as an array of AX elements.
    private func children(of element: AXUIElement) -> [AXUIElement]? {
        copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement]
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

    /// The element's frame as a valid SpatialRect, or nil when the
    /// position/size attributes are missing or the frame is invalid.
    ///
    /// AX frames use screen coordinates whose origin is the top-left corner
    /// of the menu-bar screen, with AXPosition as the top-left corner of the
    /// element and the vertical axis increasing downward
    /// (AXAttributeConstants.h). SpatialNavigator's numeric convention
    /// treats a larger `y` as "up", so a raw AX frame would make `.up` walk
    /// toward the bottom of the screen. Every frame is therefore normalized
    /// into Flux spatial coordinates by flipping the vertical axis around
    /// the element's bottom edge:
    ///
    ///     spatialX = position.x
    ///     spatialY = -(position.y + size.height)
    ///
    /// The bottom edge (larger AX y, visually lower) maps to the smaller
    /// spatial y, the top edge (smaller AX y, visually higher) maps to the
    /// larger spatial y, and width/height are unchanged. The derived frame
    /// then satisfies SpatialNavigator's rule: `.up` requires a greater
    /// candidate midY, which now corresponds to a visually higher element.
    /// SpatialRect.isValid rejects the frame when any component is
    /// nonfinite or when derived values overflow, so a pathological
    /// position/size combination can never feed the navigator.
    private func frame(of element: AXUIElement) -> SpatialRect? {
        guard let raw = rawFrame(of: element) else { return nil }
        return spatialFrame(fromRawAXFrame: raw)
    }

    /// The element's raw AX frame as a CGRect in Quartz screen coordinates
    /// (top-left origin, y downward), or nil when the position/size
    /// attributes are missing or the frame is invalid. This is the geometry
    /// the transient focus ring shows (design spec §5); the controller
    /// retains it only for the duration of one move.
    private func rawFrame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(element, kAXPositionAttribute as CFString),
              let size = sizeAttribute(element, kAXSizeAttribute as CFString) else {
            return nil
        }
        let raw = CGRect(x: position.x, y: position.y, width: size.width, height: size.height)
        return raw.isFinitePositive ? raw : nil
    }

    /// Normalizes a raw AX frame into Flux spatial coordinates (see
    /// `frame(of:)`), or nil when the derived SpatialRect is invalid.
    private func spatialFrame(fromRawAXFrame raw: CGRect) -> SpatialRect? {
        let frame = SpatialRect(
            x: raw.minX,
            y: -(raw.minY + raw.height),
            width: raw.width,
            height: raw.height
        )
        return frame.isValid ? frame : nil
    }

    // MARK: - Candidate policy

    /// Candidate eligibility (design spec §5): not hidden, enabled (a
    /// missing AXEnabled is treated as enabled), valid frame, AXFocused
    /// settable, and a standard interactive role or a supported activation
    /// action.
    private func isEligible(_ element: AXUIElement, role: String?) -> Bool {
        if let hidden = boolAttribute(element, kAXHiddenAttribute as CFString), hidden {
            return false
        }
        if let enabled = boolAttribute(element, kAXEnabledAttribute as CFString), !enabled {
            return false
        }
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable)
        guard error == .success, settable.boolValue else { return false }
        return isStandardRole(role) || supportsActivationAction(element)
    }

    /// True for roles in the standard interactive set.
    private func isStandardRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return Self.standardInteractiveRoles.contains(role)
    }

    /// True when the element supports AXPress, AXConfirm, or AXPick.
    ///
    /// Action names come from the official AXUIElementCopyActionNames API
    /// (there is no ordinary "AXActions" attribute); the returned CFArray
    /// is conditionally bridged to `[String]` so a non-string payload is
    /// treated as no supported action rather than a crash.
    private func supportsActivationAction(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        guard error == .success, let names else { return false }
        let actions = (names as? [String]) ?? []
        return actions.contains(kAXPressAction)
            || actions.contains(kAXConfirmAction)
            || actions.contains(kAXPickAction)
    }
}
