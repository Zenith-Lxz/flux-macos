import Testing
@testable import FluxCore

// MARK: - PhysicalKey

struct PhysicalKeyTests {
    @Test func unknownRawCodeRoundTrips() {
        let unknown: UInt16 = 0x7F
        let key = PhysicalKey(rawCode: unknown)
        #expect(key.rawCode == unknown)
        #expect(PhysicalKey(rawCode: unknown) == key)
        #expect(Set([key, PhysicalKey(rawCode: unknown)]).count == 1)
    }

    @Test func unknownCodeIsDistinctFromKnownKeys() {
        let unknown = PhysicalKey(rawCode: 0x40)
        #expect(unknown != .space)
        #expect(unknown != .returnKey)
        #expect(unknown != .caps)
        #expect(unknown != PhysicalKey(rawCode: 0x41))
    }

    @Test func knownKeysHaveFrozenRawCodes() {
        #expect(PhysicalKey.caps.rawCode == 0x39)
        #expect(PhysicalKey.tab.rawCode == 0x30)
        #expect(PhysicalKey.space.rawCode == 0x31)
        #expect(PhysicalKey.returnKey.rawCode == 0x24)
        #expect(PhysicalKey.escape.rawCode == 0x35)
        #expect(PhysicalKey.backspace.rawCode == 0x33)
        #expect(PhysicalKey.leftArrow.rawCode == 0x7B)
        #expect(PhysicalKey.upArrow.rawCode == 0x7E)
        #expect(PhysicalKey.rightArrow.rawCode == 0x7C)
        #expect(PhysicalKey.downArrow.rawCode == 0x7D)
    }

    @Test func lettersMapToAnsiKeyCodes() {
        let expected: [PhysicalKey: UInt16] = [
            .a: 0x00, .s: 0x01, .d: 0x02, .f: 0x03, .h: 0x04, .g: 0x05,
            .z: 0x06, .x: 0x07, .c: 0x08, .v: 0x09, .b: 0x0B, .q: 0x0C,
            .w: 0x0D, .e: 0x0E, .r: 0x0F, .y: 0x10, .t: 0x11, .o: 0x1F,
            .u: 0x20, .i: 0x22, .p: 0x23, .l: 0x25, .j: 0x26, .k: 0x28,
            .n: 0x2D, .m: 0x2E,
        ]
        #expect(expected.count == 26)
        for (key, code) in expected {
            #expect(key.rawCode == code)
        }
    }

    @Test func knownConstantsAreDistinct() {
        let constants: [PhysicalKey] = [
            .caps, .tab, .space, .returnKey, .escape, .backspace,
            .leftArrow, .upArrow, .rightArrow, .downArrow,
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
            .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
        ]
        #expect(Set(constants).count == constants.count)
    }
}

// MARK: - KeyModifiers

struct KeyModifiersTests {
    @Test func controlAggregationSeesEitherSide() {
        #expect(KeyModifiers.leftControl.control)
        #expect(KeyModifiers.rightControl.control)
        #expect(KeyModifiers([.leftControl, .rightControl]).control)
        #expect(!KeyModifiers().control)
        #expect(!KeyModifiers.leftCommand.control)
        #expect(!KeyModifiers.rightOption.control)
    }

    @Test func commandAggregationSeesEitherSide() {
        #expect(KeyModifiers.leftCommand.command)
        #expect(KeyModifiers.rightCommand.command)
        #expect(KeyModifiers([.leftCommand, .rightCommand]).command)
        #expect(!KeyModifiers().command)
        #expect(!KeyModifiers.leftControl.command)
        #expect(!KeyModifiers.rightShift.command)
    }

    @Test func optionAggregationSeesEitherSide() {
        #expect(KeyModifiers.leftOption.option)
        #expect(KeyModifiers.rightOption.option)
        #expect(KeyModifiers([.leftOption, .rightOption]).option)
        #expect(!KeyModifiers().option)
        #expect(!KeyModifiers.leftControl.option)
        #expect(!KeyModifiers.rightCommand.option)
    }

    @Test func shiftAggregationSeesEitherSide() {
        #expect(KeyModifiers.leftShift.shift)
        #expect(KeyModifiers.rightShift.shift)
        #expect(KeyModifiers([.leftShift, .rightShift]).shift)
        #expect(!KeyModifiers().shift)
        #expect(!KeyModifiers.leftControl.shift)
        #expect(!KeyModifiers.rightOption.shift)
    }

    @Test func mixedSidesAggregateIndependently() {
        let mixed = KeyModifiers([.rightControl, .leftCommand, .rightOption, .leftShift])
        #expect(mixed.control)
        #expect(mixed.command)
        #expect(mixed.option)
        #expect(mixed.shift)
        #expect(!KeyModifiers([.leftCommand, .leftOption, .leftShift]).control)
        #expect(!KeyModifiers([.leftControl, .leftOption, .leftShift]).command)
        #expect(!KeyModifiers([.leftControl, .leftCommand, .leftShift]).option)
        #expect(!KeyModifiers([.leftControl, .leftCommand, .leftOption]).shift)
    }

    @Test func removingControlKeepsOtherSixBits() {
        let all = KeyModifiers([
            .leftControl, .rightControl,
            .leftCommand, .rightCommand,
            .leftOption, .rightOption,
            .leftShift, .rightShift,
        ])
        let stripped = all.removingControl()
        #expect(stripped == [
            .leftCommand, .rightCommand,
            .leftOption, .rightOption,
            .leftShift, .rightShift,
        ])
        #expect(!stripped.control)
        #expect(stripped.command)
        #expect(stripped.option)
        #expect(stripped.shift)
    }

    @Test func removingControlClearsBothControlFlags() {
        let stripped = KeyModifiers([.leftControl, .rightControl]).removingControl()
        #expect(stripped == [])
        #expect(stripped.isEmpty)
    }

    @Test func removingControlPreservesEachIndividualSide() {
        let strippedLeft = KeyModifiers([.leftControl, .rightOption]).removingControl()
        #expect(strippedLeft == [.rightOption])
        let strippedRight = KeyModifiers([.rightControl, .leftShift]).removingControl()
        #expect(strippedRight == [.leftShift])
    }

    @Test func optionSetSemantics() {
        var mods: KeyModifiers = [.leftControl, .leftCommand]
        #expect(mods.contains(.leftCommand))
        mods.insert(.rightShift)
        #expect(mods == [.leftControl, .leftCommand, .rightShift])
        #expect(mods != [.leftControl, .rightCommand, .rightShift])
    }
}

// MARK: - InputEventKind / InputEvent

struct InputEventTests {
    @Test func kindAssociatedValuesAreDistinct() {
        #expect(InputEventKind.capsChanged(isDown: true) != InputEventKind.capsChanged(isDown: false))
        #expect(InputEventKind.capsChanged(isDown: true) == InputEventKind.capsChanged(isDown: true))
        #expect(InputEventKind.keyDown(isRepeat: true) != InputEventKind.keyDown(isRepeat: false))
        #expect(InputEventKind.keyUp != InputEventKind.keyDown(isRepeat: false))
        #expect(InputEventKind.lifecycleReset == InputEventKind.lifecycleReset)
        #expect(InputEventKind.lifecycleReset != InputEventKind.keyUp)
    }

    @Test func eventCarriesKeyModifiersSyntheticAndKind() {
        let event = InputEvent(
            key: .caps,
            modifiers: [.leftControl, .leftCommand],
            isSynthetic: true,
            kind: .keyDown(isRepeat: false)
        )
        #expect(event.key == .caps)
        #expect(event.modifiers == [.leftControl, .leftCommand])
        #expect(event.isSynthetic)
        #expect(event.kind == .keyDown(isRepeat: false))
    }

    @Test func eventEqualityAndHash() {
        let a = InputEvent(key: .escape, modifiers: [], isSynthetic: false, kind: .keyUp)
        let b = InputEvent(key: .escape, modifiers: [], isSynthetic: false, kind: .keyUp)
        let c = InputEvent(key: .escape, modifiers: [], isSynthetic: true, kind: .keyUp)
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }
}

// MARK: - FrontmostContext

struct FrontmostContextTests {
    @Test func bundleIdentifierMayBeNil() {
        #expect(FrontmostContext(bundleIdentifier: nil).bundleIdentifier == nil)
        #expect(FrontmostContext(bundleIdentifier: "com.apple.finder").bundleIdentifier == "com.apple.finder")
    }

    @Test func equalityConsidersBundleIdentifier() {
        #expect(FrontmostContext(bundleIdentifier: "com.apple.finder") == FrontmostContext(bundleIdentifier: "com.apple.finder"))
        #expect(FrontmostContext(bundleIdentifier: "com.apple.finder") != FrontmostContext(bundleIdentifier: nil))
        #expect(FrontmostContext(bundleIdentifier: nil) == FrontmostContext(bundleIdentifier: nil))
    }
}

// MARK: - Direction / PointerClickCount

struct DirectionAndPointerTests {
    @Test func directionAllCases() {
        #expect(Direction.allCases == [.up, .down, .left, .right])
        #expect(Direction.allCases.count == 4)
        #expect(Set(Direction.allCases).count == 4)
    }

    @Test func pointerClickCountAllCases() {
        #expect(PointerClickCount.allCases == [.single, .double])
        #expect(Set(PointerClickCount.allCases).count == 2)
    }
}

// MARK: - SyntheticKeyStroke

struct SyntheticKeyStrokeTests {
    @Test func strokeCarriesKeyAndModifiers() {
        let stroke = SyntheticKeyStroke(key: .y, modifiers: [.leftOption])
        #expect(stroke.key == .y)
        #expect(stroke.modifiers == [.leftOption])
        #expect(stroke == SyntheticKeyStroke(key: .y, modifiers: [.leftOption]))
        #expect(stroke != SyntheticKeyStroke(key: .y, modifiers: []))
        #expect(stroke != SyntheticKeyStroke(key: .y, modifiers: [.rightOption]))
        #expect(stroke != SyntheticKeyStroke(key: .h, modifiers: [.leftOption]))
    }
}

// MARK: - InputAction

struct InputActionTests {
    @Test func controlActionsAreDistinct() {
        #expect(InputAction.passThrough == InputAction.passThrough)
        #expect(InputAction.suppress == InputAction.suppress)
        #expect(InputAction.returnToPreviousContext == InputAction.returnToPreviousContext)
        #expect(InputAction.togglePause == InputAction.togglePause)
        #expect(InputAction.passThrough != InputAction.suppress)
        #expect(InputAction.suppress != InputAction.returnToPreviousContext)
        #expect(InputAction.togglePause != InputAction.passThrough)
    }

    @Test func moveFocusCarriesDirection() {
        #expect(InputAction.moveFocus(.up) == InputAction.moveFocus(.up))
        #expect(InputAction.moveFocus(.up) != InputAction.moveFocus(.down))
    }

    @Test func movePointerCarriesDirectionAndFastFlag() {
        #expect(
            InputAction.movePointer(direction: .up, fast: true)
                == InputAction.movePointer(direction: .up, fast: true)
        )
        #expect(
            InputAction.movePointer(direction: .up, fast: true)
                != InputAction.movePointer(direction: .down, fast: true)
        )
        #expect(
            InputAction.movePointer(direction: .up, fast: true)
                != InputAction.movePointer(direction: .up, fast: false)
        )
        #expect(
            InputAction.movePointer(direction: .left, fast: false)
                != InputAction.movePointer(direction: .right, fast: true)
        )
    }

    @Test func clickPointerCarriesClickCount() {
        #expect(InputAction.clickPointer(.single) == InputAction.clickPointer(.single))
        #expect(InputAction.clickPointer(.double) == InputAction.clickPointer(.double))
        #expect(InputAction.clickPointer(.single) != InputAction.clickPointer(.double))
    }

    @Test func emitCarriesSyntheticStroke() {
        let stroke = SyntheticKeyStroke(key: .tab, modifiers: [.leftOption])
        #expect(InputAction.emit(stroke) == InputAction.emit(SyntheticKeyStroke(key: .tab, modifiers: [.leftOption])))
        #expect(InputAction.emit(stroke) != InputAction.emit(SyntheticKeyStroke(key: .tab, modifiers: [])))
    }

    @Test func launchApplicationCarriesBundleIdentifier() {
        #expect(InputAction.launchApplication(bundleIdentifier: "com.apple.finder") == InputAction.launchApplication(bundleIdentifier: "com.apple.finder"))
        #expect(InputAction.launchApplication(bundleIdentifier: "com.apple.finder") != InputAction.launchApplication(bundleIdentifier: "com.google.Chrome"))
        #expect(InputAction.launchApplication(bundleIdentifier: "com.apple.finder") != InputAction.passThrough)
    }
}

// MARK: - AppBundleIdentifier

struct AppBundleIdentifierTests {
    @Test func frozenBundleIdsMatchDesign() {
        let expected: [AppBundleIdentifier: String] = [
            .ares: "com.ares.terminal",
            .codex: "com.openai.codex",
            .chrome: "com.google.Chrome",
            .wechat: "com.tencent.xinWeChat",
            .lark: "com.electron.lark",
            .wps: "com.kingsoft.wpsoffice.mac",
            .hermes: "com.nousresearch.hermes.setup",
            .finder: "com.apple.finder",
        ]
        #expect(AppBundleIdentifier.allCases.count == expected.count)
        for (identifier, rawValue) in expected {
            #expect(identifier.rawValue == rawValue)
        }
    }

    @Test func bundleIdsAreUniqueAndNonEmpty() {
        #expect(Set(AppBundleIdentifier.allCases.map(\.rawValue)).count == AppBundleIdentifier.allCases.count)
        #expect(!AppBundleIdentifier.allCases.contains { $0.rawValue.isEmpty })
    }
}
