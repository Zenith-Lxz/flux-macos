// FluxCore.Pointer — pointer snap eligibility policy.
//
// The platform-neutral eligibility rule for design spec §6 snapping: an AX
// element is adoptable when it is not hidden, is enabled (a missing
// AXEnabled is treated as enabled), has a valid finite positive frame, and
// either has a standard interactive role or supports an activation action
// (AXPress, AXConfirm, or AXPick). The role/action sets are plain string
// constants, so the whole rule stays
// unit-testable without Accessibility permission.

/// Eligibility policy for pointer snap candidates (design spec §6).
public enum PointerSnapEligibility: Sendable {
    /// Roles treated as interactive candidates. String literals cover roles
    /// that have no SDK constant (AXLink, AXListItem, AXTabButton) or that
    /// some apps expose under their raw role, mirroring the spatial focus
    /// candidate set (design spec §5).
    public static let standardInteractiveRoles: Set<String> = [
        "AXButton",
        "AXLink",
        "AXTextField",
        "AXTextArea",
        "AXCheckBox",
        "AXRadioButton",
        "AXMenuItem",
        "AXMenuButton",
        "AXMenuBarItem",
        "AXPopUpButton",
        "AXComboBox",
        "AXSlider",
        "AXRow",
        "AXCell",
        "AXListItem",
        "AXTabGroup",
        "AXTabButton",
    ]

    /// Activation actions that make an element eligible even when its role
    /// is not in the standard set.
    public static let activationActions: Set<String> = [
        "AXPress",
        "AXConfirm",
        "AXPick",
    ]

    /// True when an element with the given observed attributes may be a
    /// snap destination: not hidden, enabled (missing AXEnabled counts as
    /// enabled), a valid frame, and either a standard interactive role or a
    /// supported activation action.
    public static func isEligible(
        hidden: Bool?,
        enabled: Bool?,
        role: String?,
        supportedActions: Set<String>,
        frame: PointerSnapFrame
    ) -> Bool {
        if let hidden, hidden { return false }
        if let enabled, !enabled { return false }
        guard frame.isValid else { return false }
        if let role, standardInteractiveRoles.contains(role) { return true }
        return !supportedActions.isDisjoint(with: activationActions)
    }
}
