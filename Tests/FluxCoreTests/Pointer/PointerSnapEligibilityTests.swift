import Testing
@testable import FluxCore

// MARK: - Helpers

private func validFrame() -> PointerSnapFrame {
    PointerSnapFrame(x: 0, y: 0, width: 10, height: 10)
}

// MARK: - Role / action eligibility

struct PointerSnapEligibilityRoleTests {
    @Test func standardInteractiveRolesAreEligible() {
        let roles = [
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
        for role in roles {
            #expect(
                PointerSnapEligibility.isEligible(
                    hidden: nil,
                    enabled: nil,
                    role: role,
                    supportedActions: [],
                    frame: validFrame()
                )
            )
        }
    }

    @Test func activationActionMakesUnknownRoleEligible() {
        #expect(
            PointerSnapEligibility.isEligible(
                hidden: nil,
                enabled: nil,
                role: "AXUnknown",
                supportedActions: ["AXPress"],
                frame: validFrame()
            )
        )
        #expect(
            PointerSnapEligibility.isEligible(
                hidden: nil,
                enabled: nil,
                role: nil,
                supportedActions: ["AXConfirm"],
                frame: validFrame()
            )
        )
        #expect(
            PointerSnapEligibility.isEligible(
                hidden: nil,
                enabled: nil,
                role: nil,
                supportedActions: ["AXPick"],
                frame: validFrame()
            )
        )
    }

    @Test func inertUnknownElementIsNotEligible() {
        #expect(
            !PointerSnapEligibility.isEligible(
                hidden: nil,
                enabled: nil,
                role: "AXUnknown",
                supportedActions: [],
                frame: validFrame()
            )
        )
        #expect(
            !PointerSnapEligibility.isEligible(
                hidden: nil,
                enabled: nil,
                role: nil,
                supportedActions: [],
                frame: validFrame()
            )
        )
        #expect(
            !PointerSnapEligibility.isEligible(
                hidden: nil,
                enabled: nil,
                role: "AXGroup",
                supportedActions: ["AXShowMenu"],
                frame: validFrame()
            )
        )
    }

    @Test func missingRoleWithActivationActionStillEligible() {
        #expect(
            PointerSnapEligibility.isEligible(
                hidden: nil,
                enabled: nil,
                role: nil,
                supportedActions: ["AXPress"],
                frame: validFrame()
            )
        )
    }
}

// MARK: - Hidden / enabled

struct PointerSnapEligibilityStateTests {
    @Test func hiddenElementsAreNeverEligible() {
        #expect(
            !PointerSnapEligibility.isEligible(
                hidden: true,
                enabled: nil,
                role: "AXButton",
                supportedActions: [],
                frame: validFrame()
            )
        )
        #expect(
            !PointerSnapEligibility.isEligible(
                hidden: true,
                enabled: nil,
                role: nil,
                supportedActions: ["AXPress"],
                frame: validFrame()
            )
        )
    }

    @Test func disabledElementsAreNeverEligibleButMissingEnabledCountsAsEnabled() {
        #expect(
            !PointerSnapEligibility.isEligible(
                hidden: nil,
                enabled: false,
                role: "AXButton",
                supportedActions: [],
                frame: validFrame()
            )
        )
        #expect(
            PointerSnapEligibility.isEligible(
                hidden: nil,
                enabled: nil,
                role: "AXButton",
                supportedActions: [],
                frame: validFrame()
            )
        )
    }
}

// MARK: - Frame validity

struct PointerSnapEligibilityFrameTests {
    @Test func invalidFrameIsNeverEligible() {
        let invalid = PointerSnapFrame(x: 0, y: 0, width: 0, height: 10)
        #expect(
            !PointerSnapEligibility.isEligible(
                hidden: nil,
                enabled: nil,
                role: "AXButton",
                supportedActions: ["AXPress"],
                frame: invalid
            )
        )
    }

    @Test func nonFiniteFrameIsNeverEligible() {
        let invalid = PointerSnapFrame(x: .nan, y: 0, width: 10, height: 10)
        #expect(
            !PointerSnapEligibility.isEligible(
                hidden: nil,
                enabled: nil,
                role: nil,
                supportedActions: ["AXPress"],
                frame: invalid
            )
        )
    }
}

// MARK: - Conformance

struct PointerSnapEligibilityConformanceTests {
    @Test func policyDataIsSendable() {
        // Compile-time proof that the eligibility policy's data types are
        // Sendable (design spec §7 platform boundary).
        func requireSendable<T: Sendable>(_ value: T) {}
        requireSendable(PointerSnapEligibility.standardInteractiveRoles)
        requireSendable(PointerSnapEligibility.activationActions)
    }

    @Test func roleSetCoversSpatialFocusCandidates() {
        // The snap eligibility set mirrors the spatial focus interactive
        // candidates (design spec §5 vs §6); representative spatial roles
        // must all be eligible.
        let spatialRepresentatives = [
            "AXButton",
            "AXTextField",
            "AXCheckBox",
            "AXRadioButton",
            "AXMenuItem",
            "AXPopUpButton",
            "AXSlider",
            "AXTabGroup",
        ]
        for role in spatialRepresentatives {
            #expect(
                PointerSnapEligibility.isEligible(
                    hidden: nil,
                    enabled: nil,
                    role: role,
                    supportedActions: [],
                    frame: validFrame()
                )
            )
        }
    }
}
