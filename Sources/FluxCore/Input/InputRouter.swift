// FluxCore.Input — deterministic, platform-neutral input router.
//
// Maps one `InputEvent` plus the frontmost context to exactly one
// `InputAction`. The router is a mutable value type: it tracks Caps press
// state, whether the current Caps hold produced a chord, and which keys and
// modifiers were consumed so their releases stay suppressed (design spec
// §3, §7, §8, §10). The platform layer owns the CGEventTap, the private
// synthetic-event marker, and event posting; this type contains no
// AppKit/CoreGraphics code and stays unit-testable without input
// permissions.

public struct InputRouter: Sendable {
    // MARK: State

    /// Sanitized runtime configuration. Updating it clears all transient
    /// routing state so a held chord can never straddle two configurations.
    private var configuration: FluxConfiguration

    /// Whether the physical Caps Lock key is currently held.
    private var capsDown = false
    /// Whether the current Caps hold produced a chord (a routed keyDown or
    /// a modifier change). A plain Caps tap (no chord) returns to the
    /// previous context on release.
    private var chordUsed = false
    /// Keys whose keyDown was mapped; the stored descriptor decides how an
    /// OS auto-repeat (keyDown with `isRepeat` while the physical key is
    /// still held) behaves after Caps has been released: replayable actions
    /// (`emit` / `moveFocus` / `movePointer`) repeat their original action,
    /// one-shot actions (`launchApplication` / `clickPointer` /
    /// `togglePause`) are suppressed so the side effect does not repeat.
    /// The matching keyUp clears the entry; `lifecycleReset` clears every
    /// entry so stale repeats and releases route normally again.
    private var suppressedKeys: [PhysicalKey: SuppressedKeyState] = [:]
    /// Modifier keys that changed while Caps was held; their matching
    /// release must be suppressed even when Caps is released first. Cleared
    /// by `lifecycleReset`.
    private var suppressedModifiers: Set<PhysicalKey> = []

    /// How a mapped key's OS auto-repeat must behave.
    private enum SuppressedKeyState: Sendable {
        /// Replay the original action on repeat (emit / moveFocus /
        /// movePointer).
        case replay(InputAction)
        /// Suppress repeats without repeating the side effect
        /// (launchApplication / clickPointer / togglePause).
        case suppressOnly
    }

    public init(configuration: FluxConfiguration = .default) {
        self.configuration = configuration.sanitized()
    }

    /// Applies one complete configuration snapshot and clears held-key,
    /// chord, and suppression state before the next physical event.
    public mutating func updateConfiguration(_ configuration: FluxConfiguration) {
        self.configuration = configuration.sanitized()
        reset()
    }

    // MARK: Routing

    /// Routes one event and returns the deterministic action.
    ///
    /// Synthetic events always pass through and never change router state
    /// (design spec §7: the private synthetic marker prevents recursion).
    /// A non-synthetic `lifecycleReset` clears every piece of transient
    /// state: Caps down, the chord flag, and the suppressed key/modifier
    /// releases.
    public mutating func route(
        _ event: InputEvent,
        frontmost: FrontmostContext
    ) -> InputAction {
        if event.isSynthetic {
            return .passThrough
        }

        switch event.kind {
        case .lifecycleReset:
            reset()
            return .suppress

        case .capsChanged(let isDown):
            return routeCapsChanged(isDown: isDown)

        case .modifierChanged(let isDown):
            return routeModifierChanged(key: event.key, isDown: isDown)

        case .keyDown(let isRepeat):
            // Modifier keys arrive as modifierChanged; a raw keyDown for one
            // of them (or for Caps itself) is anomalous and is never mapped.
            guard !Self.isModifierKey(event.key), event.key != .caps else {
                return .passThrough
            }
            // OS auto-repeat while the physical key is still held replays
            // the original action for replayable mappings and suppresses
            // repeats of one-shot actions. This applies whether or not Caps
            // is still held: a mapped key that has not come up yet must not
            // leak as a plain key once Caps is released.
            if isRepeat, let state = suppressedKeys[event.key] {
                switch state {
                case .replay(let action):
                    return action
                case .suppressOnly:
                    return .suppress
                }
            }
            if capsDown {
                // Every key pressed under Caps belongs to the chord. The
                // chord routing always consumes the key (mapped or
                // Right-Control passthrough), so its release is suppressed.
                chordUsed = true
                let action = routeCapsChord(
                    key: event.key,
                    modifiers: event.modifiers,
                    frontmost: frontmost
                )
                rememberSuppression(for: event.key, action: action)
                return action
            } else {
                let action = routeNonCaps(
                    key: event.key,
                    modifiers: event.modifiers,
                    frontmost: frontmost
                )
                rememberSuppression(for: event.key, action: action)
                return action
            }

        case .keyUp:
            if suppressedKeys.removeValue(forKey: event.key) != nil {
                return .suppress
            }
            // Ghost release or a key that was never mapped: let it through.
            return .passThrough
        }
    }

    /// Records how a mapped keyDown must behave while the physical key stays
    /// held. A `.passThrough` result forgets any previous entry.
    private mutating func rememberSuppression(
        for key: PhysicalKey,
        action: InputAction
    ) {
        switch action {
        case .emit, .moveFocus, .movePointer:
            suppressedKeys[key] = .replay(action)
        case .launchApplication, .clickPointer, .togglePause:
            suppressedKeys[key] = .suppressOnly
        default:
            suppressedKeys.removeValue(forKey: key)
        }
    }

    // MARK: Caps state

    /// Caps Lock state changes never pass through while routing is enabled
    /// (design spec §10: physical Caps keyDown/keyUp are never forwarded as
    /// a Caps Lock toggle). A plain tap — a valid down followed by an up
    /// with no chord — returns to the previous context; a chorded hold is
    /// consumed silently.
    private mutating func routeCapsChanged(isDown: Bool) -> InputAction {
        if isDown {
            capsDown = true
            return .suppress
        }
        guard capsDown else {
            // Ghost release: no valid down was seen; consume without action.
            return .suppress
        }
        capsDown = false
        if chordUsed {
            chordUsed = false
            return .suppress
        }
        return .returnToPreviousContext
    }

    private mutating func routeModifierChanged(
        key: PhysicalKey,
        isDown: Bool
    ) -> InputAction {
        // A modifier whose press was suppressed while Caps was held keeps
        // its matching release suppressed even after Caps is released first.
        // Left Control in particular must not fall through to the
        // left-control → left-command remap (design spec §3.3, §10).
        if suppressedModifiers.contains(key) {
            if !isDown {
                suppressedModifiers.remove(key)
            }
            return .suppress
        }
        if capsDown {
            // While Caps is held every modifier change belongs to the chord:
            // mark the chord and suppress both the change and its release
            // (design spec §3.3, §10: the chord flag must be set for a
            // modifier-only hold so the Caps release is consumed).
            chordUsed = true
            if isDown {
                suppressedModifiers.insert(key)
            }
            return .suppress
        }
        if key == .leftControl,
           configuration.mappings.leftControlAsCommandEnabled {
            // Left Control is remapped to Left Command (design spec §3.3).
            return .remapModifier(to: .leftCommand, isDown: isDown)
        }
        return .passThrough
    }

    // MARK: Caps chord routing (design spec §3)

    private func routeCapsChord(
        key: PhysicalKey,
        modifiers: KeyModifiers,
        frontmost: FrontmostContext
    ) -> InputAction {
        // Escape hatch first: Caps + Command + Escape toggles pause/resume
        // on keyDown (design spec §8), ahead of every other rule.
        if key == .escape && modifiers.command {
            return .togglePause
        }

        // Pointer fallback: Option rules take priority over Command rules
        // (design spec §6, §3.2).
        if modifiers.option {
            switch key {
            case .leftArrow:
                return .movePointer(direction: .left, fast: modifiers.shift)
            case .rightArrow:
                return .movePointer(direction: .right, fast: modifiers.shift)
            case .downArrow:
                return .movePointer(direction: .down, fast: modifiers.shift)
            case .upArrow:
                return .movePointer(direction: .up, fast: modifiers.shift)
            case .returnKey:
                return .clickPointer(modifiers.shift ? .double : .single)
            default:
                break
            }
        }

        // Direct application launch: Caps + Command + memory letter.
        if modifiers.command {
            if let bundleIdentifier = applicationBundleIdentifier(for: key) {
                return .launchApplication(bundleIdentifier: bundleIdentifier)
            }
        }

        // Pure Caps chords (no Command/Option): spatial focus, text cursor
        // movement, and native Escape. The emitted strokes carry no
        // modifiers — the current Karabiner output drops Shift and any other
        // held modifier for these keys.
        if !modifiers.command && !modifiers.option {
            switch key {
            case .leftArrow:
                return .moveFocus(.left)
            case .rightArrow:
                return .moveFocus(.right)
            case .downArrow:
                return .moveFocus(.down)
            case .upArrow:
                return .moveFocus(.up)
            case .b where configuration.mappings.capsTextNavigationEnabled:
                return .emit(SyntheticKeyStroke(key: .leftArrow, modifiers: []))
            case .n where configuration.mappings.capsTextNavigationEnabled:
                return .emit(SyntheticKeyStroke(key: .downArrow, modifiers: []))
            case .p where configuration.mappings.capsTextNavigationEnabled:
                return .emit(SyntheticKeyStroke(key: .upArrow, modifiers: []))
            case .f where configuration.mappings.capsTextNavigationEnabled:
                return .emit(SyntheticKeyStroke(key: .rightArrow, modifiers: []))
            case .h where configuration.mappings.capsEditingEnabled:
                return .emit(SyntheticKeyStroke(key: .backspace, modifiers: []))
            case .o where configuration.mappings.capsEditingEnabled:
                return .emit(SyntheticKeyStroke(key: .returnKey, modifiers: []))
            case .space where configuration.mappings.capsInputSourceEnabled:
                return .emit(SyntheticKeyStroke(key: .space, modifiers: [.rightControl]))
            case .space:
                // Turning the dedicated input-source mapping off must make
                // the setting observable; emit an ordinary Space instead of
                // falling into the generic Right-Control passthrough.
                return .emit(SyntheticKeyStroke(key: .space, modifiers: modifiers))
            case .escape:
                return .emit(SyntheticKeyStroke(key: .escape, modifiers: []))
            case .tab where configuration.mappings.chromeTabEnabled:
                if frontmost.bundleIdentifier == configuration.applications.chrome {
                    return .emit(SyntheticKeyStroke(key: .y, modifiers: [.leftOption]))
                }
            default:
                break
            }
        }

        // Unassigned Caps chords pass through as Right Control + key so
        // terminal Ctrl+A/C/R/L/W/Z etc. keep working; unknown keys are
        // never swallowed (design spec §3.3).
        return .emit(
            SyntheticKeyStroke(key: key, modifiers: modifiers.union([.rightControl]))
        )
    }

    // MARK: Non-Caps routing (design spec §3.3)

    private func routeNonCaps(
        key: PhysicalKey,
        modifiers: KeyModifiers,
        frontmost: FrontmostContext
    ) -> InputAction {
        // Migration compatibility: a pure Command+C in iTerm2 / ToDesk /
        // `st` becomes Control+C. The rule is closable in settings; the
        // router only applies it to the exact terminal bundles.
        if key == .c,
           configuration.mappings.legacyTerminalCopyEnabled,
           modifiers == [.leftCommand] || modifiers == [.rightCommand],
           Self.terminalBundles.contains(frontmost.bundleIdentifier ?? "") {
            return .emit(SyntheticKeyStroke(key: .c, modifiers: [.leftControl]))
        }

        // Command + E becomes Command + M. The current Karabiner output
        // always emits a plain Left Command + M: Shift, Option, and Control
        // are not preserved.
        if key == .e,
           configuration.mappings.commandEToCommandMEnabled,
           modifiers.command {
            return .emit(SyntheticKeyStroke(key: .m, modifiers: [.leftCommand]))
        }

        // Left Control + M becomes Return; it takes priority over the
        // generic Left Control mapping and always emits with no modifiers.
        if key == .m,
           configuration.mappings.leftControlMAsReturnEnabled,
           modifiers.contains(.leftControl) {
            return .emit(SyntheticKeyStroke(key: .returnKey, modifiers: []))
        }

        // Other Left Control chords become Left Command + the same key,
        // keeping every other modifier.
        if configuration.mappings.leftControlAsCommandEnabled,
           modifiers.contains(.leftControl) {
            let outputModifiers = modifiers
                .subtracting([.leftControl])
                .union([.leftCommand])
            return .emit(SyntheticKeyStroke(key: key, modifiers: outputModifiers))
        }

        return .passThrough
    }

    // MARK: State reset

    private mutating func reset() {
        capsDown = false
        chordUsed = false
        suppressedKeys.removeAll()
        suppressedModifiers.removeAll()
    }

    // MARK: Frozen tables

    /// Resolves one direct-launch key through the current semantic app
    /// bindings. A nil binding deliberately disables that key and lets the
    /// ordinary Right-Control fallback handle it.
    private func applicationBundleIdentifier(for key: PhysicalKey) -> String? {
        switch key {
        case .a: configuration.applications.ares
        case .c: configuration.applications.codex
        case .g: configuration.applications.chrome
        case .x: configuration.applications.wechat
        case .l: configuration.applications.lark
        case .w: configuration.applications.wps
        case .h: configuration.applications.hermes
        case .f: configuration.applications.finder
        default: nil
        }
    }

    /// Terminals that opt into the Command+C → Control+C compatibility rule
    /// (design spec §3.3).
    private static let terminalBundles: Set<String> = [
        "com.googlecode.iterm2",
        "com.youqu.todesk.mac",
        "st",
    ]

    private static let modifierKeys: Set<PhysicalKey> = [
        .leftControl, .rightControl,
        .leftCommand, .rightCommand,
        .leftOption, .rightOption,
        .leftShift, .rightShift,
    ]

    private static func isModifierKey(_ key: PhysicalKey) -> Bool {
        modifierKeys.contains(key)
    }
}
