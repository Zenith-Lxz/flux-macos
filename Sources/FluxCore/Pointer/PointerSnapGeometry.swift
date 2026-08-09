// FluxCore.Pointer — pointer snap geometry and selection.
//
// Platform-neutral snapping rules for design spec §6: after a keyboard
// pointer move, the platform layer asks whether a nearby interactive AX
// element's center is close enough to adopt as the pointer destination.
// These value types and the pure selector carry no AppKit/CoreGraphics or
// Accessibility types, so radius-boundary, nearest-center, depth tie-break,
// and invalid/overflow geometry rules stay unit-testable without macOS
// permissions (design spec §7: platform boundaries are injected behind
// protocols).

/// A point in Quartz global screen coordinates (top-left origin, +Y down).
public struct PointerSnapPoint: Sendable, Equatable, Hashable {
    /// Horizontal coordinate.
    public let x: Double
    /// Vertical coordinate.
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// True when both coordinates are finite; a non-finite point can never
    /// anchor a deterministic distance comparison.
    public var isValid: Bool {
        x.isFinite && y.isFinite
    }
}

/// An axis-aligned frame in Quartz global screen coordinates (top-left
/// origin, +Y down), matching CGEvent cursor locations.
public struct PointerSnapFrame: Sendable, Equatable, Hashable {
    /// Left edge.
    public let x: Double
    /// Top edge.
    public let y: Double
    /// Width; must be strictly positive for a valid frame.
    public let width: Double
    /// Height; must be strictly positive for a valid frame.
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Center x (`x + width / 2`).
    public var midX: Double { x + width / 2 }
    /// Center y (`y + height / 2`).
    public var midY: Double { y + height / 2 }

    /// True when every component is finite, both `width` and `height` are
    /// strictly positive, and the derived center coordinates are finite.
    /// Finite stored components alone are not enough: `x + width / 2` can
    /// overflow to infinity for extreme inputs, which would admit invalid
    /// distances and break deterministic selection.
    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
            && (x + width).isFinite && (y + height).isFinite
            && midX.isFinite && midY.isFinite
    }
}

/// One candidate in the snap chain: the element found at the pointer
/// position (depth 0) plus up to `PointerSnapPolicy.maxDepth` ancestors.
public struct PointerSnapCandidate: Sendable, Equatable, Hashable {
    /// Stable identity used for the deterministic total-order tie-break.
    public let identifier: String
    /// The element's frame in Quartz global screen coordinates.
    public let frame: PointerSnapFrame
    /// Tree distance from the hit element: 0 is the element found at the
    /// position, 1 is its parent, and so on.
    public let depth: Int

    public init(identifier: String, frame: PointerSnapFrame, depth: Int) {
        self.identifier = identifier
        self.frame = frame
        self.depth = depth
    }
}

/// Tuning knobs for pointer snap selection (design spec §6: a conservative
/// 32pt acceptance radius and at most 3 ancestors inspected).
///
/// The constructor sanitizes inputs deterministically: a non-finite or
/// non-positive radius falls back to 32, larger radii clamp to 32, and
/// ancestor depth clamps into 0...3.
public struct PointerSnapPolicy: Sendable, Equatable, Hashable {
    /// Maximum Euclidean distance between the geometric target and a
    /// candidate center, in points.
    public let radius: Double
    /// Maximum ancestor depth considered; the element at the position is
    /// depth 0, so a `maxDepth` of 3 inspects at most 4 elements.
    public let maxDepth: Int

    /// The default policy: a 32-point radius and 3 ancestors.
    public static let `default` = PointerSnapPolicy()

    public init(radius: Double = 32, maxDepth: Int = 3) {
        self.radius = (radius.isFinite && radius > 0) ? min(radius, 32) : 32
        self.maxDepth = maxDepth >= 0 ? min(maxDepth, 3) : 3
    }
}

/// Deterministic nearest-center snap selection.
///
/// Selection is a pure function of the candidate list, the geometric
/// target, and the policy: the same inputs always produce the same result
/// regardless of array order. Candidates whose frames are invalid, whose
/// center distance is non-finite (including overflow), or whose depth
/// exceeds the policy are ignored; the winner is the candidate whose center
/// is nearest to the target within the radius, ties broken by shallower
/// depth (the element closest to the pointer wins over its ancestors), then
/// by identifier.
public struct PointerSnapSelector: Sendable {
    public init() {}

    /// Selects the best snap candidate, or nil when no candidate is within
    /// the acceptance radius or the target is not a finite point.
    public func select(
        from candidates: [PointerSnapCandidate],
        target: PointerSnapPoint,
        policy: PointerSnapPolicy = .init()
    ) -> PointerSnapCandidate? {
        guard target.isValid else { return nil }
        let radiusSquared = policy.radius * policy.radius
        var best: PointerSnapCandidate?
        var bestDistanceSquared: Double = .infinity
        for candidate in candidates {
            guard candidate.frame.isValid,
                  candidate.depth >= 0,
                  candidate.depth <= policy.maxDepth else { continue }
            let dx = candidate.frame.midX - target.x
            let dy = candidate.frame.midY - target.y
            // Non-finite deltas (from overflow) and non-finite squared
            // distances (overflow of the product) are never admitted.
            guard dx.isFinite, dy.isFinite else { continue }
            let distanceSquared = dx * dx + dy * dy
            guard distanceSquared.isFinite, distanceSquared <= radiusSquared else { continue }
            guard let current = best else {
                best = candidate
                bestDistanceSquared = distanceSquared
                continue
            }
            if isPreferred(candidate, distanceSquared, over: current, bestDistanceSquared) {
                best = candidate
                bestDistanceSquared = distanceSquared
            }
        }
        return best
    }

    /// True when `candidate` beats `current`: strictly nearer center, or
    /// equal distance with shallower depth, or equal distance and depth
    /// with the lexicographically smaller identifier.
    private func isPreferred(
        _ candidate: PointerSnapCandidate,
        _ distanceSquared: Double,
        over current: PointerSnapCandidate,
        _ currentDistanceSquared: Double
    ) -> Bool {
        if distanceSquared != currentDistanceSquared {
            return distanceSquared < currentDistanceSquared
        }
        if candidate.depth != current.depth {
            return candidate.depth < current.depth
        }
        return candidate.identifier < current.identifier
    }
}
