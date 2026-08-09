// FluxCore.Input — deterministic sided-modifier state.
//
// CoreGraphics reports Control, Command, Option, and Shift as aggregate
// flags even though Flux routing depends on the physical left/right side.
// This tracker combines the changing key code with that aggregate state so
// the macOS event-tap layer can produce a stable KeyModifiers value.

/// One physical modifier transition and the complete state after it.
public struct ModifierTransition: Sendable, Equatable, Hashable {
    public let isDown: Bool
    public let modifiers: KeyModifiers

    public init(isDown: Bool, modifiers: KeyModifiers) {
        self.isDown = isDown
        self.modifiers = modifiers
    }
}

/// Tracks all eight sided modifier keys.
///
/// A `flagsChanged` event identifies the side that changed while its flags
/// expose only the aggregate family state. When that side is already
/// tracked, its next change is a release even if the aggregate remains on
/// because the opposite side is still held. An untracked side is a press
/// only when the aggregate flag is on; aggregate-off input is treated as a
/// harmless ghost release, which makes lifecycle recovery fail closed.
public struct ModifierStateTracker: Sendable {
    public private(set) var modifiers: KeyModifiers = []

    public init() {}

    /// Applies one physical `flagsChanged` transition.
    ///
    /// Returns nil for non-modifier key codes and never mutates state for
    /// them. The returned modifier set is the complete state after the
    /// transition.
    public mutating func transition(
        for key: PhysicalKey,
        aggregateIsActive: Bool
    ) -> ModifierTransition? {
        guard let modifier = Self.modifier(for: key) else { return nil }

        let isDown: Bool
        if modifiers.contains(modifier) {
            isDown = false
            modifiers.remove(modifier)
        } else if aggregateIsActive {
            isDown = true
            modifiers.insert(modifier)
        } else {
            isDown = false
        }

        return ModifierTransition(isDown: isDown, modifiers: modifiers)
    }

    /// Clears all transient state after an event-tap lifecycle interruption.
    public mutating func reset() {
        modifiers = []
    }

    /// The sided KeyModifiers bit associated with a physical modifier key.
    private static func modifier(for key: PhysicalKey) -> KeyModifiers? {
        switch key {
        case .leftControl:
            return .leftControl
        case .rightControl:
            return .rightControl
        case .leftCommand:
            return .leftCommand
        case .rightCommand:
            return .rightCommand
        case .leftOption:
            return .leftOption
        case .rightOption:
            return .rightOption
        case .leftShift:
            return .leftShift
        case .rightShift:
            return .rightShift
        default:
            return nil
        }
    }
}
