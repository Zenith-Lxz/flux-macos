// FluxCore.Input — platform-independent input models.
//
// These models depend only on Swift value types (UInt16, String?, Bool) and
// carry no AppKit/CoreGraphics types, so key routing, spatial scoring, and
// context history stay unit-testable without macOS input permissions
// (design spec §7: platform boundaries are injected behind protocols).

/// A physical keyboard key identified by its raw code.
///
/// `rawCode` is the platform virtual key code (macOS HIToolbox `kVK_*`).
/// Codes Flux does not map are preserved verbatim so unassigned keys pass
/// through untouched (design spec §3.3).
public struct PhysicalKey: Sendable, Equatable, Hashable {
    public let rawCode: UInt16

    public init(rawCode: UInt16) {
        self.rawCode = rawCode
    }

    // MARK: Frozen known keys (macOS virtual key codes)

    /// Caps Lock (`kVK_CapsLock`, 0x39).
    public static let caps = PhysicalKey(rawCode: 0x39)
    /// Tab (`kVK_Tab`, 0x30).
    public static let tab = PhysicalKey(rawCode: 0x30)
    /// Space (`kVK_Space`, 0x31).
    public static let space = PhysicalKey(rawCode: 0x31)
    /// Return (`kVK_Return`, 0x24).
    public static let returnKey = PhysicalKey(rawCode: 0x24)
    /// Escape (`kVK_Escape`, 0x35).
    public static let escape = PhysicalKey(rawCode: 0x35)
    /// Backspace / Delete (`kVK_Delete`, 0x33).
    public static let backspace = PhysicalKey(rawCode: 0x33)

    /// Left arrow (`kVK_LeftArrow`, 0x7B).
    public static let leftArrow = PhysicalKey(rawCode: 0x7B)
    /// Right arrow (`kVK_RightArrow`, 0x7C).
    public static let rightArrow = PhysicalKey(rawCode: 0x7C)
    /// Down arrow (`kVK_DownArrow`, 0x7D).
    public static let downArrow = PhysicalKey(rawCode: 0x7D)
    /// Up arrow (`kVK_UpArrow`, 0x7E).
    public static let upArrow = PhysicalKey(rawCode: 0x7E)

    // ANSI letters (`kVK_ANSI_*`).
    public static let a = PhysicalKey(rawCode: 0x00)
    public static let s = PhysicalKey(rawCode: 0x01)
    public static let d = PhysicalKey(rawCode: 0x02)
    public static let f = PhysicalKey(rawCode: 0x03)
    public static let h = PhysicalKey(rawCode: 0x04)
    public static let g = PhysicalKey(rawCode: 0x05)
    public static let z = PhysicalKey(rawCode: 0x06)
    public static let x = PhysicalKey(rawCode: 0x07)
    public static let c = PhysicalKey(rawCode: 0x08)
    public static let v = PhysicalKey(rawCode: 0x09)
    public static let b = PhysicalKey(rawCode: 0x0B)
    public static let q = PhysicalKey(rawCode: 0x0C)
    public static let w = PhysicalKey(rawCode: 0x0D)
    public static let e = PhysicalKey(rawCode: 0x0E)
    public static let r = PhysicalKey(rawCode: 0x0F)
    public static let y = PhysicalKey(rawCode: 0x10)
    public static let t = PhysicalKey(rawCode: 0x11)
    public static let o = PhysicalKey(rawCode: 0x1F)
    public static let u = PhysicalKey(rawCode: 0x20)
    public static let i = PhysicalKey(rawCode: 0x22)
    public static let p = PhysicalKey(rawCode: 0x23)
    public static let l = PhysicalKey(rawCode: 0x25)
    public static let j = PhysicalKey(rawCode: 0x26)
    public static let k = PhysicalKey(rawCode: 0x28)
    public static let n = PhysicalKey(rawCode: 0x2D)
    public static let m = PhysicalKey(rawCode: 0x2E)
}

/// Modifier keys as a set.
///
/// Control, Command, Option, and Shift are each split into an independent
/// `left*` / `right*` bit so the router can apply the left-control →
/// left-command mapping and the right-control passthrough independently
/// (design spec §3.3). The aggregated `control` / `command` / `option` /
/// `shift` properties report whether either side of that modifier is held.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let leftControl = KeyModifiers(rawValue: 1 << 0)
    public static let rightControl = KeyModifiers(rawValue: 1 << 1)
    public static let leftCommand = KeyModifiers(rawValue: 1 << 2)
    public static let rightCommand = KeyModifiers(rawValue: 1 << 3)
    public static let leftOption = KeyModifiers(rawValue: 1 << 4)
    public static let rightOption = KeyModifiers(rawValue: 1 << 5)
    public static let leftShift = KeyModifiers(rawValue: 1 << 6)
    public static let rightShift = KeyModifiers(rawValue: 1 << 7)

    /// True when either Control key is held.
    public var control: Bool {
        contains(.leftControl) || contains(.rightControl)
    }

    /// True when either Command key is held.
    public var command: Bool {
        contains(.leftCommand) || contains(.rightCommand)
    }

    /// True when either Option key is held.
    public var option: Bool {
        contains(.leftOption) || contains(.rightOption)
    }

    /// True when either Shift key is held.
    public var shift: Bool {
        contains(.leftShift) || contains(.rightShift)
    }

    /// Returns a copy with both Control flags cleared, preserving every other
    /// modifier. Used by the left-control → left-command mapping (design
    /// spec §3.3).
    public func removingControl() -> KeyModifiers {
        subtracting([.leftControl, .rightControl])
    }
}

/// The kind of an observed or synthetic input event.
///
/// `capsChanged` reports the physical Caps Lock key press/release state and
/// is the only way Flux tracks Caps; physical Caps keyDown/keyUp must never
/// be forwarded as a Caps Lock toggle (design spec §10).
public enum InputEventKind: Sendable, Equatable, Hashable {
    /// Physical Caps Lock state changed; `isDown` is the new pressed state.
    case capsChanged(isDown: Bool)
    /// A key press; `isRepeat` distinguishes OS auto-repeat from the first
    /// press.
    case keyDown(isRepeat: Bool)
    /// A key release.
    case keyUp
    /// Forced state reset (for example after the event tap is disabled and
    /// before it is re-enabled, design spec §7).
    case lifecycleReset
}

/// One observed input event, platform-neutral.
public struct InputEvent: Sendable, Equatable, Hashable {
    public let key: PhysicalKey
    public let modifiers: KeyModifiers
    public let isSynthetic: Bool
    public let kind: InputEventKind

    public init(
        key: PhysicalKey,
        modifiers: KeyModifiers,
        isSynthetic: Bool,
        kind: InputEventKind
    ) {
        self.key = key
        self.modifiers = modifiers
        self.isSynthetic = isSynthetic
        self.kind = kind
    }
}

/// The frontmost application context Flux tracks.
///
/// The full runtime context also carries a process identifier and a window
/// reference (design spec §4); this model keeps the nullable bundle
/// identifier, which is the only field key routing needs.
public struct FrontmostContext: Sendable, Equatable, Hashable {
    public let bundleIdentifier: String?

    public init(bundleIdentifier: String?) {
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Spatial direction for focus and pointer navigation (design spec §5, §6).
public enum Direction: CaseIterable, Sendable, Equatable, Hashable {
    case up
    case down
    case left
    case right
}

/// Pointer primary-button click count (design spec §6: single click with
/// `Caps + Option + Return`, double click with
/// `Caps + Option + Shift + Return`).
public enum PointerClickCount: CaseIterable, Sendable, Equatable, Hashable {
    case single
    case double
}

/// A key stroke Flux asks the system to emit, carrying the private synthetic
/// marker at the event-tap boundary (design spec §7).
public struct SyntheticKeyStroke: Sendable, Equatable, Hashable {
    public let key: PhysicalKey
    public let modifiers: KeyModifiers

    public init(key: PhysicalKey, modifiers: KeyModifiers) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// The deterministic result of routing one input event.
///
/// One of these is produced per routed event; the platform layer then either
/// suppresses the original event, lets it through, or posts the synthetic
/// replacement (design spec §3, §7).
public enum InputAction: Sendable, Equatable, Hashable {
    /// Let the original event reach the system untouched.
    case passThrough
    /// Consume the original event and do nothing else.
    case suppress
    /// Emit the given synthetic stroke (with the private marker).
    case emit(SyntheticKeyStroke)
    /// Swap the current and previous contexts (single Caps press).
    case returnToPreviousContext
    /// Move the accessibility focus in a direction.
    case moveFocus(Direction)
    /// Move the pointer in a direction; `fast` selects the Shift fast mode.
    case movePointer(direction: Direction, fast: Bool)
    /// Click the pointer primary button the given number of times.
    case clickPointer(PointerClickCount)
    /// Launch (or focus) the application with the given bundle identifier.
    case launchApplication(bundleIdentifier: String)
    /// Toggle pause / resume (design spec §8: `Caps + Command + Escape`).
    case togglePause
}

/// Frozen default bundle identifiers for the eight direct-launch targets
/// (design spec §3.2, validated on this machine).
public enum AppBundleIdentifier: String, CaseIterable, Sendable, Equatable, Hashable {
    case ares = "com.ares.terminal"
    case codex = "com.openai.codex"
    case chrome = "com.google.Chrome"
    case wechat = "com.tencent.xinWeChat"
    case lark = "com.electron.lark"
    case wps = "com.kingsoft.wpsoffice.mac"
    case hermes = "com.nousresearch.hermes.setup"
    case finder = "com.apple.finder"
}
