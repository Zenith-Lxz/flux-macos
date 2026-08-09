import Testing
@testable import FluxCore

// MARK: - Helpers

private func route(
    _ router: inout InputRouter,
    key: PhysicalKey,
    modifiers: KeyModifiers = [],
    synthetic: Bool = false,
    kind: InputEventKind = .keyDown(isRepeat: false),
    frontmost: String? = nil
) -> InputAction {
    router.route(
        InputEvent(
            key: key,
            modifiers: modifiers,
            isSynthetic: synthetic,
            kind: kind
        ),
        frontmost: FrontmostContext(bundleIdentifier: frontmost)
    )
}

private func capsDown(_ router: inout InputRouter) -> InputAction {
    route(&router, key: .caps, kind: .capsChanged(isDown: true))
}

private func capsUp(_ router: inout InputRouter) -> InputAction {
    route(&router, key: .caps, kind: .capsChanged(isDown: false))
}

private func modifierChanged(_ router: inout InputRouter, key: PhysicalKey, isDown: Bool) -> InputAction {
    route(&router, key: key, kind: .modifierChanged(isDown: isDown))
}

private func keyDown(
    _ router: inout InputRouter,
    key: PhysicalKey,
    modifiers: KeyModifiers = [],
    isRepeat: Bool = false,
    synthetic: Bool = false,
    frontmost: String? = nil
) -> InputAction {
    route(&router, key: key, modifiers: modifiers, synthetic: synthetic, kind: .keyDown(isRepeat: isRepeat), frontmost: frontmost)
}

private func keyUp(
    _ router: inout InputRouter,
    key: PhysicalKey,
    modifiers: KeyModifiers = [],
    frontmost: String? = nil
) -> InputAction {
    route(&router, key: key, modifiers: modifiers, kind: .keyUp, frontmost: frontmost)
}

private func emit(_ key: PhysicalKey, _ modifiers: KeyModifiers) -> InputAction {
    .emit(SyntheticKeyStroke(key: key, modifiers: modifiers))
}

private let chrome = "com.google.Chrome"
private let finder = "com.apple.finder"
private let iTerm2 = "com.googlecode.iterm2"
private let toDesk = "com.youqu.todesk.mac"
private let st = "st"

// MARK: - Caps tap state

struct InputRouterCapsTapTests {
    @Test func singleCapsTapReturnsToPreviousContext() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(capsUp(&router) == .returnToPreviousContext)
    }

    @Test func twoConsecutiveTapsEachReturn() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(capsUp(&router) == .returnToPreviousContext)
        #expect(capsDown(&router) == .suppress)
        #expect(capsUp(&router) == .returnToPreviousContext)
    }

    @Test func capsChangedNeverPassesThrough() {
        var router = InputRouter()
        // Down, tap return, and ghost up are all consumed, never forwarded.
        #expect(capsDown(&router) != .passThrough)
        #expect(capsUp(&router) != .passThrough)
        #expect(capsUp(&router) != .passThrough) // ghost up after release
        #expect(capsDown(&router) != .passThrough)
    }

    @Test func ghostCapsUpWithoutDownIsConsumed() {
        var router = InputRouter()
        #expect(capsUp(&router) == .suppress)
        #expect(capsUp(&router) == .suppress)
    }

    @Test func ghostCapsDownWhileDownIsConsumed() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(capsDown(&router) == .suppress)
        #expect(capsUp(&router) == .returnToPreviousContext)
    }
}

// MARK: - Chord state, repeat, ghost, synthetic, reset

struct InputRouterChordStateTests {
    @Test func capsChordSuppressesCapsRelease() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .leftArrow) == .moveFocus(.left))
        #expect(keyUp(&router, key: .leftArrow) == .suppress)
        // Chord consumed the Caps hold: no context return.
        #expect(capsUp(&router) == .suppress)
    }

    @Test func repeatKeyDownReproducesChordAction() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .leftArrow) == .moveFocus(.left))
        #expect(keyDown(&router, key: .leftArrow, isRepeat: true) == .moveFocus(.left))
        #expect(keyDown(&router, key: .leftArrow, isRepeat: true) == .moveFocus(.left))
    }

    @Test func repeatOfMappedKeyStillSuppressesItsRelease() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .b) == emit(.leftArrow, []))
        #expect(keyDown(&router, key: .b, isRepeat: true) == emit(.leftArrow, []))
        #expect(keyUp(&router, key: .b) == .suppress)
        #expect(capsUp(&router) == .suppress)
    }

    @Test func ghostKeyUpPassesThrough() {
        var router = InputRouter()
        #expect(keyUp(&router, key: .a) == .passThrough)
        #expect(keyUp(&router, key: .leftArrow) == .passThrough)
    }

    @Test func ghostKeyUpAfterRealReleasePassesThrough() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .b) == emit(.leftArrow, []))
        #expect(keyUp(&router, key: .b) == .suppress)
        // A second release is a ghost and is not suppressed again.
        #expect(keyUp(&router, key: .b) == .passThrough)
    }

    @Test func mappedKeyDownKeyUpIsSuppressedAcrossCapsRelease() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .b) == emit(.leftArrow, []))
        #expect(capsUp(&router) == .suppress) // chord used
        // The release of the mapped key stays suppressed after Caps is up.
        #expect(keyUp(&router, key: .b) == .suppress)
    }

    @Test func repeatAfterCapsReleaseReplaysMappedAction() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .b) == emit(.leftArrow, []))
        #expect(capsUp(&router) == .suppress)
        // The physical key never came up: OS auto-repeat after Caps release
        // replays the original action instead of leaking a plain key.
        #expect(keyDown(&router, key: .b, isRepeat: true) == emit(.leftArrow, []))
        #expect(keyUp(&router, key: .b) == .suppress)
    }

    @Test func repeatOfMovePointerReplaysAfterCapsRelease() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(
            keyDown(&router, key: .leftArrow, modifiers: [.leftOption])
                == .movePointer(direction: .left, fast: false)
        )
        #expect(capsUp(&router) == .suppress)
        #expect(
            keyDown(&router, key: .leftArrow, modifiers: [.leftOption], isRepeat: true)
                == .movePointer(direction: .left, fast: false)
        )
        #expect(keyUp(&router, key: .leftArrow) == .suppress)
    }

    @Test func repeatOfLaunchApplicationSuppressesSideEffect() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(
            keyDown(&router, key: .a, modifiers: [.leftCommand])
                == .launchApplication(bundleIdentifier: AppBundleIdentifier.ares.rawValue)
        )
        #expect(capsUp(&router) == .suppress)
        // One-shot action: the repeat is consumed without relaunching.
        #expect(keyDown(&router, key: .a, modifiers: [.leftCommand], isRepeat: true) == .suppress)
        #expect(keyUp(&router, key: .a) == .suppress)
    }

    @Test func repeatOfClickPointerSuppressesSideEffect() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .returnKey, modifiers: [.leftOption]) == .clickPointer(.single))
        #expect(capsUp(&router) == .suppress)
        // One-shot action: the repeat is consumed without clicking again.
        #expect(keyDown(&router, key: .returnKey, modifiers: [.leftOption], isRepeat: true) == .suppress)
        #expect(keyUp(&router, key: .returnKey) == .suppress)
    }

    @Test func repeatOfTogglePauseSuppressesSideEffect() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .escape, modifiers: [.leftCommand]) == .togglePause)
        #expect(capsUp(&router) == .suppress)
        // One-shot action: the repeat is consumed without toggling twice.
        #expect(keyDown(&router, key: .escape, modifiers: [.leftCommand], isRepeat: true) == .suppress)
        #expect(keyUp(&router, key: .escape) == .suppress)
    }

    @Test func repeatAfterKeyUpUsesPlainRouting() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .b) == emit(.leftArrow, []))
        #expect(keyUp(&router, key: .b) == .suppress)
        #expect(capsUp(&router) == .suppress)
        // The mapping is forgotten once the physical key came up.
        #expect(keyDown(&router, key: .b, isRepeat: true) == .passThrough)
    }

    @Test func lifecycleResetRestoresPlainRoutingForRepeat() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .b) == emit(.leftArrow, []))
        #expect(route(&router, key: .escape, kind: .lifecycleReset) == .suppress)
        // After reset a stale repeat and release route normally again.
        #expect(keyDown(&router, key: .b, isRepeat: true) == .passThrough)
        #expect(keyUp(&router, key: .b) == .passThrough)
    }

    @Test func syntheticEventsPassThroughWithoutStateChange() {
        var router = InputRouter()
        // Synthetic Caps events do not alter Caps state.
        #expect(route(&router, key: .caps, synthetic: true, kind: .capsChanged(isDown: true)) == .passThrough)
        #expect(capsDown(&router) == .suppress)
        #expect(capsUp(&router) == .returnToPreviousContext)
        // Synthetic chord key does not mark the chord.
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .b, synthetic: true) == .passThrough)
        #expect(capsUp(&router) == .returnToPreviousContext)
        // Synthetic modifier change does not mark the chord.
        #expect(capsDown(&router) == .suppress)
        #expect(route(&router, key: .leftOption, synthetic: true, kind: .modifierChanged(isDown: true)) == .passThrough)
        #expect(capsUp(&router) == .returnToPreviousContext)
        // Synthetic lifecycleReset does not reset state.
        #expect(capsDown(&router) == .suppress)
        #expect(route(&router, key: .escape, synthetic: true, kind: .lifecycleReset) == .passThrough)
        #expect(capsUp(&router) == .returnToPreviousContext)
        // Synthetic keyUp is never suppressed.
        #expect(route(&router, key: .a, synthetic: true, kind: .keyUp) == .passThrough)
    }

    @Test func lifecycleResetClearsAllTransientState() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .b) == emit(.leftArrow, []))
        #expect(route(&router, key: .escape, kind: .lifecycleReset) == .suppress)
        // Old keyUp is no longer suppressed after reset.
        #expect(keyUp(&router, key: .b) == .passThrough)
        // Caps ghost up is consumed; a fresh tap returns again.
        #expect(capsUp(&router) == .suppress)
        #expect(capsDown(&router) == .suppress)
        #expect(capsUp(&router) == .returnToPreviousContext)
    }

    @Test func lifecycleResetClearsSuppressedModifierState() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(modifierChanged(&router, key: .leftOption, isDown: true) == .suppress)
        #expect(route(&router, key: .escape, kind: .lifecycleReset) == .suppress)
        // After reset the old modifier release is not suppressed in caps mode
        // because caps is no longer down; it falls through as a plain change.
        #expect(modifierChanged(&router, key: .leftOption, isDown: false) == .passThrough)
    }
}

// MARK: - Modifier-only chord

struct InputRouterModifierOnlyTests {
    @Test func capsWithModifierOnlyMarksChordAndSuppressesReleases() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(modifierChanged(&router, key: .leftOption, isDown: true) == .suppress)
        #expect(modifierChanged(&router, key: .leftOption, isDown: false) == .suppress)
        #expect(capsUp(&router) == .suppress)
    }

    @Test func everyModifierChangeWhileCapsDownIsSuppressed() {
        let modifiers: [PhysicalKey] = [
            .leftControl, .rightControl,
            .leftCommand, .rightCommand,
            .leftOption, .rightOption,
            .leftShift, .rightShift,
        ]
        for key in modifiers {
            var router = InputRouter()
            #expect(capsDown(&router) == .suppress)
            #expect(modifierChanged(&router, key: key, isDown: true) == .suppress)
            #expect(modifierChanged(&router, key: key, isDown: false) == .suppress)
            #expect(capsUp(&router) == .suppress)
        }
    }

    @Test func ghostModifierReleaseWhileCapsDownIsSuppressed() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(modifierChanged(&router, key: .leftShift, isDown: false) == .suppress)
        #expect(capsUp(&router) == .suppress)
    }

    @Test func optionReleaseStaysSuppressedAfterCapsReleasedFirst() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(modifierChanged(&router, key: .leftOption, isDown: true) == .suppress)
        #expect(capsUp(&router) == .suppress)
        // Caps came up first, but the Option release was suppressed while it
        // went down, so its release must stay suppressed too.
        #expect(modifierChanged(&router, key: .leftOption, isDown: false) == .suppress)
    }

    @Test func leftControlReleaseStaysSuppressedAfterCapsReleasedFirst() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(modifierChanged(&router, key: .leftControl, isDown: true) == .suppress)
        #expect(capsUp(&router) == .suppress)
        // The Left Control release must not fall through to the
        // left-control → left-command remap after Caps is already up.
        #expect(modifierChanged(&router, key: .leftControl, isDown: false) == .suppress)
    }

    @Test func lifecycleResetRestoresOrdinaryRoutingForSuppressedModifierRelease() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(modifierChanged(&router, key: .leftControl, isDown: true) == .suppress)
        #expect(route(&router, key: .escape, kind: .lifecycleReset) == .suppress)
        // After reset the old release routes ordinarily again: Left Control
        // release is remapped to Left Command release, not suppressed.
        #expect(
            modifierChanged(&router, key: .leftControl, isDown: false)
                == .remapModifier(to: .leftCommand, isDown: false)
        )
    }
}

// MARK: - Caps chord routing rules

struct InputRouterCapsRoutingTests {
    @Test func capsCommandEscapeTogglesPause() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .escape, modifiers: [.leftCommand]) == .togglePause)
        #expect(keyUp(&router, key: .escape) == .suppress)
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsOptionArrowsMovePointer() {
        let cases: [(PhysicalKey, Direction)] = [
            (.leftArrow, .left), (.rightArrow, .right),
            (.downArrow, .down), (.upArrow, .up),
        ]
        for (key, direction) in cases {
            var router = InputRouter()
            #expect(capsDown(&router) == .suppress)
            #expect(keyDown(&router, key: key, modifiers: [.leftOption]) == .movePointer(direction: direction, fast: false))
            #expect(capsUp(&router) == .suppress)
        }
    }

    @Test func capsOptionShiftArrowMovesPointerFast() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(
            keyDown(&router, key: .upArrow, modifiers: [.leftOption, .leftShift])
                == .movePointer(direction: .up, fast: true)
        )
        #expect(capsUp(&router) == .suppress)
    }

    @Test func optionPointerRuleWinsOverCommandAppRule() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(
            keyDown(&router, key: .leftArrow, modifiers: [.leftOption, .leftCommand])
                == .movePointer(direction: .left, fast: false)
        )
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsOptionReturnClicksSingle() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .returnKey, modifiers: [.rightOption]) == .clickPointer(.single))
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsOptionShiftReturnClicksDouble() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(
            keyDown(&router, key: .returnKey, modifiers: [.leftOption, .leftShift])
                == .clickPointer(.double)
        )
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsCommandLettersLaunchFrozenBundleIds() {
        let cases: [(PhysicalKey, AppBundleIdentifier)] = [
            (.a, .ares), (.c, .codex), (.g, .chrome), (.x, .wechat),
            (.l, .lark), (.w, .wps), (.h, .hermes), (.f, .finder),
        ]
        for (key, app) in cases {
            var router = InputRouter()
            #expect(capsDown(&router) == .suppress)
            #expect(
                keyDown(&router, key: key, modifiers: [.leftCommand])
                    == .launchApplication(bundleIdentifier: app.rawValue)
            )
            #expect(keyUp(&router, key: key) == .suppress)
            #expect(capsUp(&router) == .suppress)
        }
    }

    @Test func capsCommandUnassignedLetterFallsBackWithRightControl() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .e, modifiers: [.leftCommand]) == emit(.e, [.leftCommand, .rightControl]))
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsNoModifierArrowsMoveFocus() {
        let cases: [(PhysicalKey, Direction)] = [
            (.leftArrow, .left), (.rightArrow, .right),
            (.downArrow, .down), (.upArrow, .up),
        ]
        for (key, direction) in cases {
            var router = InputRouter()
            #expect(capsDown(&router) == .suppress)
            #expect(keyDown(&router, key: key) == .moveFocus(direction))
            #expect(capsUp(&router) == .suppress)
        }
    }

    @Test func capsBnpfMapToTextArrows() {
        let cases: [(PhysicalKey, PhysicalKey)] = [
            (.b, .leftArrow), (.n, .downArrow), (.p, .upArrow), (.f, .rightArrow),
        ]
        for (key, target) in cases {
            var router = InputRouter()
            #expect(capsDown(&router) == .suppress)
            #expect(keyDown(&router, key: key) == emit(target, []))
            #expect(capsUp(&router) == .suppress)
        }
    }

    @Test func capsHBackspace() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .h) == emit(.backspace, []))
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsOReturn() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .o) == emit(.returnKey, []))
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsEscapeEmitsNativeEscape() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .escape) == emit(.escape, []))
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsTextMovementDropsShift() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        // Karabiner emits the target key with no modifiers; Shift is not
        // preserved for B/N/P/F/H/O/Escape.
        #expect(keyDown(&router, key: .b, modifiers: [.leftShift]) == emit(.leftArrow, []))
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsSpaceAddsRightControl() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .space) == emit(.space, [.rightControl]))
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsSpacePreservesOptionAndShift() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(
            keyDown(&router, key: .space, modifiers: [.leftOption, .leftShift])
                == emit(.space, [.leftOption, .leftShift, .rightControl])
        )
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsSpaceWithCommandFallsBackWithRightControl() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .space, modifiers: [.leftCommand]) == emit(.space, [.leftCommand, .rightControl]))
        #expect(capsUp(&router) == .suppress)
    }

    @Test func chromeCapsTabMapsToLeftOptionY() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .tab, frontmost: chrome) == emit(.y, [.leftOption]))
        #expect(capsUp(&router) == .suppress)
    }

    @Test func nonChromeCapsTabMapsToRightControlTab() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .tab, frontmost: finder) == emit(.tab, [.rightControl]))
        #expect(capsUp(&router) == .suppress)
    }

    @Test func nonChromeCapsShiftTabPreservesShift() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(
            keyDown(&router, key: .tab, modifiers: [.leftShift], frontmost: finder)
                == emit(.tab, [.leftShift, .rightControl])
        )
        #expect(capsUp(&router) == .suppress)
    }

    @Test func chromeCapsCommandTabFallsBack() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(
            keyDown(&router, key: .tab, modifiers: [.leftCommand], frontmost: chrome)
                == emit(.tab, [.leftCommand, .rightControl])
        )
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsUnknownKeyFallsBackWithRightControl() {
        let unknown = PhysicalKey(rawCode: 0x7F)
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: unknown) == emit(unknown, [.rightControl]))
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsOptionUnassignedLetterFallsBack() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .x, modifiers: [.leftOption]) == emit(.x, [.leftOption, .rightControl]))
        #expect(capsUp(&router) == .suppress)
    }

    @Test func capsKeyDownOfModifierKeyIsNeverRouted() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .leftOption, modifiers: [.leftOption]) == .passThrough)
        #expect(keyDown(&router, key: .leftCommand, modifiers: [.leftCommand]) == .passThrough)
        // No chord was marked by the anomalous modifier keyDown.
        #expect(capsUp(&router) == .returnToPreviousContext)
    }

    @Test func capsKeyDownOfCapsIsNeverRouted() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .caps) == .passThrough)
        #expect(capsUp(&router) == .returnToPreviousContext)
    }
}

// MARK: - Non-Caps routing

struct InputRouterNonCapsRoutingTests {
    @Test func leftControlMMapsToReturn() {
        var router = InputRouter()
        #expect(keyDown(&router, key: .m, modifiers: [.leftControl]) == emit(.returnKey, []))
        #expect(keyUp(&router, key: .m) == .suppress)
    }

    @Test func leftControlShiftMMapsToPlainReturn() {
        var router = InputRouter()
        #expect(
            keyDown(&router, key: .m, modifiers: [.leftControl, .leftShift])
                == emit(.returnKey, [])
        )
        #expect(keyUp(&router, key: .m) == .suppress)
    }

    @Test func leftControlGenericMapsToLeftCommand() {
        var router = InputRouter()
        #expect(keyDown(&router, key: .a, modifiers: [.leftControl]) == emit(.a, [.leftCommand]))
        #expect(keyUp(&router, key: .a) == .suppress)
    }

    @Test func leftControlGenericPreservesOtherModifiers() {
        var router = InputRouter()
        #expect(
            keyDown(&router, key: .a, modifiers: [.leftControl, .leftShift])
                == emit(.a, [.leftShift, .leftCommand])
        )
        #expect(
            keyDown(&router, key: .a, modifiers: [.leftControl, .rightControl])
                == emit(.a, [.rightControl, .leftCommand])
        )
        #expect(
            keyDown(&router, key: .a, modifiers: [.leftControl, .leftOption])
                == emit(.a, [.leftOption, .leftCommand])
        )
    }

    @Test func leftControlMappingDoesNotApplyToModifierKeys() {
        var router = InputRouter()
        #expect(keyDown(&router, key: .leftControl, modifiers: [.leftControl]) == .passThrough)
        #expect(keyDown(&router, key: .rightControl, modifiers: [.leftControl]) == .passThrough)
    }

    @Test func commandEMapsToLeftCommandM() {
        var router = InputRouter()
        #expect(keyDown(&router, key: .e, modifiers: [.leftCommand]) == emit(.m, [.leftCommand]))
        #expect(keyUp(&router, key: .e) == .suppress)
    }

    @Test func rightCommandEMapsToLeftCommandM() {
        var router = InputRouter()
        #expect(keyDown(&router, key: .e, modifiers: [.rightCommand]) == emit(.m, [.leftCommand]))
        #expect(keyUp(&router, key: .e) == .suppress)
    }

    @Test func commandShiftEDropsShift() {
        var router = InputRouter()
        // Karabiner always emits a plain Left Command + M; Shift is dropped.
        #expect(
            keyDown(&router, key: .e, modifiers: [.leftCommand, .leftShift])
                == emit(.m, [.leftCommand])
        )
        #expect(
            keyDown(&router, key: .e, modifiers: [.leftCommand, .leftOption, .leftControl])
                == emit(.m, [.leftCommand])
        )
    }

    @Test func pureCommandCInItermMapsToLeftControlC() {
        var router = InputRouter()
        #expect(keyDown(&router, key: .c, modifiers: [.leftCommand], frontmost: iTerm2) == emit(.c, [.leftControl]))
        #expect(keyUp(&router, key: .c) == .suppress)
    }

    @Test func pureCommandCInToDeskMapsToLeftControlC() {
        var router = InputRouter()
        #expect(keyDown(&router, key: .c, modifiers: [.leftCommand], frontmost: toDesk) == emit(.c, [.leftControl]))
    }

    @Test func pureCommandCInSTerminalMapsToLeftControlC() {
        var router = InputRouter()
        #expect(keyDown(&router, key: .c, modifiers: [.rightCommand], frontmost: st) == emit(.c, [.leftControl]))
    }

    @Test func pureCommandCOutsideTerminalsPassesThrough() {
        var router = InputRouter()
        #expect(keyDown(&router, key: .c, modifiers: [.leftCommand], frontmost: finder) == .passThrough)
        #expect(keyDown(&router, key: .c, modifiers: [.leftCommand], frontmost: chrome) == .passThrough)
        #expect(keyDown(&router, key: .c, modifiers: [.leftCommand], frontmost: nil) == .passThrough)
    }

    @Test func impureCommandCInTerminalPassesThrough() {
        var router = InputRouter()
        #expect(
            keyDown(&router, key: .c, modifiers: [.leftCommand, .leftShift], frontmost: iTerm2)
                == .passThrough
        )
        #expect(
            keyDown(&router, key: .c, modifiers: [.leftCommand, .leftOption], frontmost: iTerm2)
                == .passThrough
        )
        #expect(
            keyDown(&router, key: .c, modifiers: [.leftCommand, .leftControl], frontmost: iTerm2)
                == emit(.c, [.leftCommand])
        )
    }

    @Test func plainKeyPassesThrough() {
        var router = InputRouter()
        #expect(keyDown(&router, key: .a) == .passThrough)
        #expect(keyDown(&router, key: .m) == .passThrough)
        #expect(keyUp(&router, key: .a) == .passThrough)
    }

    @Test func unknownKeyPassesThroughWithoutCaps() {
        let unknown = PhysicalKey(rawCode: 0x7F)
        var router = InputRouter()
        #expect(keyDown(&router, key: unknown) == .passThrough)
        #expect(keyUp(&router, key: unknown) == .passThrough)
    }

    @Test func mappedNonCapsKeyUpsAreSuppressed() {
        var router = InputRouter()
        #expect(keyDown(&router, key: .a, modifiers: [.leftControl]) == emit(.a, [.leftCommand]))
        #expect(keyUp(&router, key: .a) == .suppress)
        #expect(keyDown(&router, key: .e, modifiers: [.leftCommand]) == emit(.m, [.leftCommand]))
        #expect(keyUp(&router, key: .e) == .suppress)
        #expect(keyDown(&router, key: .c, modifiers: [.leftCommand], frontmost: iTerm2) == emit(.c, [.leftControl]))
        #expect(keyUp(&router, key: .c) == .suppress)
    }
}

// MARK: - ModifierChanged routing (non-Caps)

struct InputRouterModifierChangedTests {
    @Test func leftControlModifierChangedRemapsToLeftCommand() {
        var router = InputRouter()
        #expect(
            modifierChanged(&router, key: .leftControl, isDown: true)
                == .remapModifier(to: .leftCommand, isDown: true)
        )
        #expect(
            modifierChanged(&router, key: .leftControl, isDown: false)
                == .remapModifier(to: .leftCommand, isDown: false)
        )
    }

    @Test func otherModifierChangesPassThrough() {
        let modifiers: [PhysicalKey] = [
            .rightControl,
            .leftCommand, .rightCommand,
            .leftOption, .rightOption,
            .leftShift, .rightShift,
        ]
        for key in modifiers {
            var router = InputRouter()
            #expect(modifierChanged(&router, key: key, isDown: true) == .passThrough)
            #expect(modifierChanged(&router, key: key, isDown: false) == .passThrough)
        }
    }

    @Test func leftControlModifierChangedWhileCapsDownIsSuppressed() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(modifierChanged(&router, key: .leftControl, isDown: true) == .suppress)
        #expect(modifierChanged(&router, key: .leftControl, isDown: false) == .suppress)
        #expect(capsUp(&router) == .suppress)
    }

    @Test func modifierChangedForCapsPassesThrough() {
        var router = InputRouter()
        #expect(modifierChanged(&router, key: .caps, isDown: true) == .passThrough)
    }
}

// MARK: - Rule priority and integration

struct InputRouterPriorityTests {
    @Test func escapeHatchWinsOverPointerRule() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(
            keyDown(&router, key: .escape, modifiers: [.leftCommand, .leftOption])
                == .togglePause
        )
    }

    @Test func pointerRuleWinsOverFocusRule() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(
            keyDown(&router, key: .rightArrow, modifiers: [.leftOption])
                == .movePointer(direction: .right, fast: false)
        )
        #expect(
            keyDown(&router, key: .rightArrow, modifiers: [.leftOption, .leftCommand])
                == .movePointer(direction: .right, fast: false)
        )
    }

    @Test func appDirectWinsOverFocusAndTextMovement() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .h, modifiers: [.leftCommand]) == .launchApplication(bundleIdentifier: AppBundleIdentifier.hermes.rawValue))
        #expect(keyDown(&router, key: .f, modifiers: [.leftCommand]) == .launchApplication(bundleIdentifier: AppBundleIdentifier.finder.rawValue))
    }

    @Test func unassignedCapsCommandKeysAreNeverSwallowed() {
        let keys: [PhysicalKey] = [.k, .j, .q, .tab, .space, PhysicalKey(rawCode: 0x7F)]
        for key in keys {
            var router = InputRouter()
            #expect(capsDown(&router) == .suppress)
            let action = keyDown(&router, key: key, modifiers: [.leftCommand])
            if case .emit(let stroke) = action {
                #expect(stroke.modifiers.contains(.rightControl))
                #expect(stroke.key == key)
            } else {
                Issue.record("expected emit for \(key.rawCode), got \(action)")
            }
        }
    }
}

// MARK: - Runtime configuration

struct InputRouterConfigurationTests {
    @Test func customAndDisabledApplicationBindingsDriveDirectLaunches() {
        var router = InputRouter(
            configuration: FluxConfiguration(
                applications: .init(
                    ares: "com.example.ares",
                    codex: nil
                )
            )
        )

        #expect(capsDown(&router) == .suppress)
        #expect(
            keyDown(&router, key: .a, modifiers: [.leftCommand])
                == .launchApplication(bundleIdentifier: "com.example.ares")
        )
        #expect(keyUp(&router, key: .a) == .suppress)
        #expect(capsUp(&router) == .suppress)

        #expect(capsDown(&router) == .suppress)
        #expect(
            keyDown(&router, key: .c, modifiers: [.leftCommand])
                == emit(.c, [.leftCommand, .rightControl])
        )
    }

    @Test func disabledCapsTextAndEditingMappingsUseRightControlFallback() {
        var router = InputRouter(
            configuration: FluxConfiguration(
                mappings: .init(
                    capsTextNavigationEnabled: false,
                    capsEditingEnabled: false
                )
            )
        )

        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .b) == emit(.b, [.rightControl]))
        #expect(keyDown(&router, key: .h) == emit(.h, [.rightControl]))
        #expect(keyDown(&router, key: .o) == emit(.o, [.rightControl]))
    }

    @Test func chromeTabUsesConfiguredBundleAndCanBeDisabled() {
        let applications = FluxConfiguration.Applications(chrome: "com.example.browser")
        var customRouter = InputRouter(
            configuration: FluxConfiguration(applications: applications)
        )
        #expect(capsDown(&customRouter) == .suppress)
        #expect(
            keyDown(&customRouter, key: .tab, frontmost: "com.example.browser")
                == emit(.y, [.leftOption])
        )

        var disabledRouter = InputRouter(
            configuration: FluxConfiguration(
                applications: applications,
                mappings: .init(chromeTabEnabled: false)
            )
        )
        #expect(capsDown(&disabledRouter) == .suppress)
        #expect(
            keyDown(&disabledRouter, key: .tab, frontmost: "com.example.browser")
                == emit(.tab, [.rightControl])
        )
    }

    @Test func disabledCapsInputSourceEmitsOrdinarySpace() {
        var router = InputRouter(
            configuration: FluxConfiguration(
                mappings: .init(capsInputSourceEnabled: false)
            )
        )

        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .space) == emit(.space, []))
        #expect(
            keyDown(&router, key: .space, modifiers: [.leftShift])
                == emit(.space, [.leftShift])
        )
    }

    @Test func nonCapsMappingsCanBeDisabledIndependently() {
        var router = InputRouter(
            configuration: FluxConfiguration(
                mappings: .init(
                    leftControlAsCommandEnabled: false,
                    leftControlMAsReturnEnabled: false,
                    commandEToCommandMEnabled: false,
                    legacyTerminalCopyEnabled: false
                )
            )
        )

        #expect(modifierChanged(&router, key: .leftControl, isDown: true) == .passThrough)
        #expect(keyDown(&router, key: .a, modifiers: [.leftControl]) == .passThrough)
        #expect(keyDown(&router, key: .m, modifiers: [.leftControl]) == .passThrough)
        #expect(keyDown(&router, key: .e, modifiers: [.leftCommand]) == .passThrough)
        #expect(
            keyDown(&router, key: .c, modifiers: [.leftCommand], frontmost: iTerm2)
                == .passThrough
        )
    }

    @Test func disabledControlMStillUsesEnabledGenericControlMapping() {
        var router = InputRouter(
            configuration: FluxConfiguration(
                mappings: .init(leftControlMAsReturnEnabled: false)
            )
        )

        #expect(
            keyDown(&router, key: .m, modifiers: [.leftControl])
                == emit(.m, [.leftCommand])
        )
    }

    @Test func updatingConfigurationResetsHeldChordState() {
        var router = InputRouter()
        #expect(capsDown(&router) == .suppress)

        router.updateConfiguration(FluxConfiguration(mappings: .init(capsEditingEnabled: false)))

        #expect(capsUp(&router) == .suppress)
        #expect(capsDown(&router) == .suppress)
        #expect(keyDown(&router, key: .h) == emit(.h, [.rightControl]))
    }
}
