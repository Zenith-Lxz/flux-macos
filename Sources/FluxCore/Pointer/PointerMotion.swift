// FluxCore.Pointer — platform-neutral pointer motion state machine.
//
// Converts repeated pointer-key events into deterministic logical deltas with
// tiered acceleration (design spec §6: short press for fine movement, long
// press accelerates through normal → accelerated → maximum tiers, Shift
// selects the fast tier). The machine depends only on Swift value types and
// carries no AppKit/CoreGraphics types, so pointer motion stays unit-testable
// without macOS permissions (design spec §7: platform boundaries are injected
// behind protocols).

/// A logical pointer displacement.
///
/// Coordinates are logical, not screen: right is +dx, left is -dx, up is
/// +dy, and down is -dy. The platform layer maps these onto the screen
/// (design spec §6).
public struct PointerDelta: Sendable, Equatable, Hashable {
    /// Displacement along the horizontal axis; positive is right.
    public let dx: Double
    /// Displacement along the vertical axis; positive is up.
    public let dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

/// Tuning knobs for pointer motion.
///
/// The constructor sanitizes inputs deterministically: a non-finite or
/// non-positive step or reset interval falls back to that field's default, a
/// negative threshold falls back to that field's default, and the maximum
/// repeat threshold is raised to the acceleration threshold when it would
/// otherwise sit below it.
public struct PointerMotionProfile: Sendable, Equatable, Hashable {
    /// Step for a fresh sequence, before acceleration (repeat counts below
    /// `accelerationRepeatThreshold`).
    public let normalStep: Double
    /// Step once the repeat count reaches `accelerationRepeatThreshold`.
    public let acceleratedStep: Double
    /// Step once the repeat count reaches `maximumRepeatThreshold`.
    public let maximumStep: Double
    /// Step used whenever `fast` is true, regardless of the repeat tier.
    public let fastStep: Double
    /// Repeat count at which acceleration begins.
    public let accelerationRepeatThreshold: Int
    /// Repeat count at which the maximum tier begins.
    public let maximumRepeatThreshold: Int
    /// Maximum gap between a repeat and the prior event that continues a
    /// sequence, in seconds.
    public let resetInterval: Double

    /// The default profile: 12 / 24 / 48 / 72 steps, 4 / 12 repeat
    /// thresholds, and a 0.20 s reset interval.
    public static let `default` = PointerMotionProfile()

    public init(
        normalStep: Double = 12,
        acceleratedStep: Double = 24,
        maximumStep: Double = 48,
        fastStep: Double = 72,
        accelerationRepeatThreshold: Int = 4,
        maximumRepeatThreshold: Int = 12,
        resetInterval: Double = 0.20
    ) {
        self.normalStep = Self.sanitizedStep(normalStep, fallback: 12)
        self.acceleratedStep = Self.sanitizedStep(acceleratedStep, fallback: 24)
        self.maximumStep = Self.sanitizedStep(maximumStep, fallback: 48)
        self.fastStep = Self.sanitizedStep(fastStep, fallback: 72)
        self.accelerationRepeatThreshold = Self.sanitizedThreshold(
            accelerationRepeatThreshold, fallback: 4)
        let sanitizedMaximumThreshold = Self.sanitizedThreshold(
            maximumRepeatThreshold, fallback: 12)
        self.maximumRepeatThreshold = max(
            sanitizedMaximumThreshold, self.accelerationRepeatThreshold)
        self.resetInterval = Self.sanitizedStep(resetInterval, fallback: 0.20)
    }

    /// Returns this profile with only its four movement magnitudes scaled.
    /// The settings range is 0.5...2.0; non-finite multipliers fall back to
    /// 1.0. Thresholds and timing remain unchanged so speed customization
    /// cannot alter acceleration-state semantics.
    public func scaled(by multiplier: Double) -> PointerMotionProfile {
        let boundedMultiplier: Double
        if multiplier.isFinite {
            boundedMultiplier = min(max(multiplier, 0.5), 2.0)
        } else {
            boundedMultiplier = 1.0
        }
        func scaledStep(_ step: Double) -> Double {
            let result = step * boundedMultiplier
            return result.isFinite && result > 0 ? result : step
        }
        return PointerMotionProfile(
            normalStep: scaledStep(normalStep),
            acceleratedStep: scaledStep(acceleratedStep),
            maximumStep: scaledStep(maximumStep),
            fastStep: scaledStep(fastStep),
            accelerationRepeatThreshold: accelerationRepeatThreshold,
            maximumRepeatThreshold: maximumRepeatThreshold,
            resetInterval: resetInterval
        )
    }

    /// A finite positive value, or the fallback.
    private static func sanitizedStep(_ value: Double, fallback: Double) -> Double {
        value.isFinite && value > 0 ? value : fallback
    }

    /// A nonnegative value, or the fallback.
    private static func sanitizedThreshold(_ value: Int, fallback: Int) -> Int {
        value >= 0 ? value : fallback
    }
}

/// Deterministic pointer motion sequence.
///
/// `delta` decides per event whether a repeat continues the current sequence
/// — same direction, finite non-decreasing timestamps, gap within
/// `resetInterval` — and selects the step tier from the repeat count. Every
/// non-repeat, and every repeat that fails the continuation check, starts a
/// fresh sequence at repeat count zero.
public struct PointerMotionState: Sendable {
    /// The profile this machine moves with.
    public let profile: PointerMotionProfile
    /// Number of consecutive continuing repeats since the sequence started.
    /// Read-only; updated by `delta` and cleared by `reset`.
    public private(set) var repeatCount: Int = 0

    private var direction: Direction?
    private var lastTimestamp: Double?

    public init(profile: PointerMotionProfile = .default) {
        self.profile = profile
    }

    /// Saturating repeat-count increment.
    ///
    /// Returns `Int.max` when `value` is already `Int.max`, otherwise
    /// `value + 1`. Continuing repeats use this instead of unchecked `+= 1`
    /// so a pathological event stream can never trap on integer overflow;
    /// the step tier already saturates at the maximum tier for any count at
    /// or above `maximumRepeatThreshold`.
    internal static func saturatingIncrement(_ value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }

    /// Returns the logical delta for one pointer-key event and updates the
    /// sequence state.
    ///
    /// - Parameters:
    ///   - direction: The direction of the key event.
    ///   - fast: Whether the Shift fast tier is active. Fast events always
    ///     return `profile.fastStep` but still advance or reset the sequence
    ///     exactly like non-fast events.
    ///   - isRepeat: Whether this event is an auto-repeat of a held key.
    ///   - timestamp: Event time in seconds. Non-finite values never anchor a
    ///     sequence.
    public mutating func delta(
        direction: Direction,
        fast: Bool,
        isRepeat: Bool,
        timestamp: Double
    ) -> PointerDelta {
        if isRepeat && canContinue(direction: direction, timestamp: timestamp) {
            repeatCount = Self.saturatingIncrement(repeatCount)
            lastTimestamp = timestamp
            return step(direction: direction, fast: fast, repeatCount: repeatCount)
        }
        beginSequence(direction: direction, timestamp: timestamp)
        return step(direction: direction, fast: fast, repeatCount: 0)
    }

    /// Clears the sequence; the next event starts fresh.
    public mutating func reset() {
        direction = nil
        lastTimestamp = nil
        repeatCount = 0
    }

    /// Whether a repeat may continue the current sequence.
    private func canContinue(direction: Direction, timestamp: Double) -> Bool {
        guard let priorDirection = self.direction,
              let priorTimestamp = self.lastTimestamp,
              direction == priorDirection,
              timestamp.isFinite,
              timestamp >= priorTimestamp,
              timestamp - priorTimestamp <= profile.resetInterval else {
            return false
        }
        return true
    }

    /// Starts a fresh sequence from the given event.
    private mutating func beginSequence(direction: Direction, timestamp: Double) {
        self.direction = direction
        // A non-finite timestamp cannot anchor a sequence; keeping it out of
        // state guarantees no NaN leaks into later gap math.
        lastTimestamp = timestamp.isFinite ? timestamp : nil
        repeatCount = 0
    }

    /// The logical delta for one event at the given tier.
    private func step(direction: Direction, fast: Bool, repeatCount: Int) -> PointerDelta {
        let magnitude: Double
        if fast {
            magnitude = profile.fastStep
        } else if repeatCount < profile.accelerationRepeatThreshold {
            magnitude = profile.normalStep
        } else if repeatCount < profile.maximumRepeatThreshold {
            magnitude = profile.acceleratedStep
        } else {
            magnitude = profile.maximumStep
        }
        switch direction {
        case .up:
            return PointerDelta(dx: 0, dy: magnitude)
        case .down:
            return PointerDelta(dx: 0, dy: -magnitude)
        case .left:
            return PointerDelta(dx: -magnitude, dy: 0)
        case .right:
            return PointerDelta(dx: magnitude, dy: 0)
        }
    }
}
