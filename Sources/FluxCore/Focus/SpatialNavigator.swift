// FluxCore.Focus — platform-neutral spatial focus selection.
//
// Deterministic spatial scoring for `Caps + direction` focus navigation
// (design spec §5). The models depend only on Swift value types (Double,
// String?, Int) and carry no AppKit/CoreGraphics or Accessibility types, so
// spatial selection stays unit-testable without macOS permissions (design
// spec §7: platform boundaries are injected behind protocols).

/// An axis-aligned rectangle in a numeric 2D space.
///
/// Coordinates are plain numbers with no locale or UI convention implied.
/// The navigator's half-plane rule treats larger `y` as "up" only in the
/// numeric sense defined by `SpatialNavigator.select` (`up` requires the
/// candidate center's `midY` to be strictly greater than the source's).
public struct SpatialRect: Sendable, Equatable, Hashable {
    /// The left edge x coordinate.
    public let x: Double
    /// The smaller y edge coordinate.
    public let y: Double
    /// The extent along the x axis; must be positive for a valid frame.
    public let width: Double
    /// The extent along the y axis; must be positive for a valid frame.
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The left edge.
    public var minX: Double { x }
    /// The smaller y edge.
    public var minY: Double { y }
    /// The right edge (`x + width`).
    public var maxX: Double { x + width }
    /// The larger y edge (`y + height`).
    public var maxY: Double { y + height }
    /// The center x (`x + width / 2`).
    public var midX: Double { x + width / 2 }
    /// The center y (`y + height / 2`).
    public var midY: Double { y + height / 2 }

    /// True when every component is finite, both `width` and `height` are
    /// strictly positive, and the derived edges and centers (`maxX`,
    /// `maxY`, `midX`, `midY`) are all finite. Finite stored components
    /// alone are not enough: `x + width` and `y + height` can overflow to
    /// infinity, which would admit invalid scores and break deterministic
    /// ordering.
    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
            && maxX.isFinite && maxY.isFinite && midX.isFinite && midY.isFinite
    }

    /// True when the y-intervals overlap with positive length (the rects are
    /// aligned on the vertical axis). This is the perpendicular-overlap test
    /// for left/right navigation.
    public func yRangesOverlap(with other: SpatialRect) -> Bool {
        minY < other.maxY && maxY > other.minY
    }

    /// True when the x-intervals overlap with positive length (the rects are
    /// aligned on the horizontal axis). This is the perpendicular-overlap
    /// test for up/down navigation.
    public func xRangesOverlap(with other: SpatialRect) -> Bool {
        minX < other.maxX && maxX > other.minX
    }
}

/// One selectable element in spatial navigation.
public struct SpatialCandidate: Sendable, Equatable, Hashable {
    /// Stable identity used to drop the source and to provide the final
    /// total-order safety tie-break.
    public let identifier: String
    /// The element's frame in the numeric 2D space.
    public let frame: SpatialRect
    /// Optional region (for example "sidebar", "content", "toolbar") used
    /// to keep navigation inside the current region before leaving it
    /// (design spec §5).
    public let regionIdentifier: String?
    /// The stable traversal order index produced by the AX tree walk.
    public let traversalIndex: Int

    public init(
        identifier: String,
        frame: SpatialRect,
        regionIdentifier: String? = nil,
        traversalIndex: Int = 0
    ) {
        self.identifier = identifier
        self.frame = frame
        self.regionIdentifier = regionIdentifier
        self.traversalIndex = traversalIndex
    }
}

/// Deterministic spatial focus selection for `Caps + direction`.
///
/// Selection is a pure function of the source and the candidate list: the
/// same inputs always produce the same result regardless of array order.
/// Scoring follows design spec §5: drop the source and out-of-half-plane
/// candidates, stay in the source region while any same-region candidate is
/// eligible, then minimize the lexicographic score (main-axis gap,
/// perpendicular overlap, perpendicular center offset, screen coordinates
/// `y` then `x`, traversal index, identifier).
public struct SpatialNavigator: Sendable {
    public init() {}

    /// Selects the best candidate in `direction` from `candidates`.
    ///
    /// - Parameters:
    ///   - source: the current focus element. The caller typically also
    ///     includes it in `candidates`, where it is dropped by identifier.
    ///   - candidates: all observed elements to choose from.
    ///   - direction: the requested movement.
    /// - Returns: the winning candidate, or nil when the source frame is
    ///   invalid or no eligible candidate exists.
    public func select(
        from source: SpatialCandidate,
        candidates: [SpatialCandidate],
        direction: Direction
    ) -> SpatialCandidate? {
        guard source.frame.isValid else { return nil }

        // 1. Drop the source itself (same identifier), invalid frames, and
        //    candidates not in the requested target half-plane (centers).
        var eligible = candidates.filter { candidate in
            candidate.identifier != source.identifier
                && candidate.frame.isValid
                && isInHalfPlane(candidate.frame, relativeTo: source.frame, direction: direction)
        }
        guard !eligible.isEmpty else { return nil }

        // 2. Region clustering: while at least one eligible candidate shares
        //    the source region, score only those same-region candidates.
        //    A nil source region never clusters.
        if let region = source.regionIdentifier {
            let sameRegion = eligible.filter { $0.regionIdentifier == region }
            if !sameRegion.isEmpty {
                eligible = sameRegion
            }
        }

        // 3. Lexicographic minimum score; smaller wins. The identifier
        //    component makes the total order strict, so the winner is
        //    independent of input array order.
        var best: SpatialCandidate?
        var bestScore: Score?
        for candidate in eligible {
            let score = score(for: candidate, relativeTo: source, direction: direction)
            if let current = bestScore {
                if score < current {
                    bestScore = score
                    best = candidate
                }
            } else {
                bestScore = score
                best = candidate
            }
        }
        return best
    }
}

/// Lexicographic selection score; smaller wins (design spec §5).
private struct Score: Sendable, Comparable {
    /// Main-axis edge distance from the source edge, clamped at zero.
    var mainAxisGap: Double
    /// Perpendicular overlap rank: 0 overlapping, 1 non-overlapping.
    var overlapRank: Int
    /// Absolute perpendicular center offset.
    var perpendicularCenterOffset: Double
    /// Screen-coordinate tie-break, y first.
    var minY: Double
    /// Screen-coordinate tie-break, then x.
    var minX: Double
    /// Stable traversal order index.
    var traversalIndex: Int
    /// Final total-order safety.
    var identifier: String

    static func < (lhs: Score, rhs: Score) -> Bool {
        if lhs.mainAxisGap != rhs.mainAxisGap {
            return lhs.mainAxisGap < rhs.mainAxisGap
        }
        if lhs.overlapRank != rhs.overlapRank {
            return lhs.overlapRank < rhs.overlapRank
        }
        if lhs.perpendicularCenterOffset != rhs.perpendicularCenterOffset {
            return lhs.perpendicularCenterOffset < rhs.perpendicularCenterOffset
        }
        if lhs.minY != rhs.minY {
            return lhs.minY < rhs.minY
        }
        if lhs.minX != rhs.minX {
            return lhs.minX < rhs.minX
        }
        if lhs.traversalIndex != rhs.traversalIndex {
            return lhs.traversalIndex < rhs.traversalIndex
        }
        return lhs.identifier < rhs.identifier
    }
}

private extension SpatialNavigator {
    /// True when the candidate center lies strictly in the target half-plane
    /// of the source center: right means `midX >`, left `midX <`, up
    /// `midY >`, down `midY <`. No locale or UI convention is assumed.
    func isInHalfPlane(
        _ candidate: SpatialRect,
        relativeTo source: SpatialRect,
        direction: Direction
    ) -> Bool {
        switch direction {
        case .right: return candidate.midX > source.midX
        case .left: return candidate.midX < source.midX
        case .up: return candidate.midY > source.midY
        case .down: return candidate.midY < source.midY
        }
    }

    /// The gap between the source's trailing edge and the candidate's
    /// leading edge along the main axis, clamped at zero for frames that
    /// already touch or overlap on that axis.
    func mainAxisGap(
        _ candidate: SpatialRect,
        relativeTo source: SpatialRect,
        direction: Direction
    ) -> Double {
        switch direction {
        case .right: return max(0, candidate.minX - source.maxX)
        case .left: return max(0, source.minX - candidate.maxX)
        case .up: return max(0, candidate.minY - source.maxY)
        case .down: return max(0, source.minY - candidate.maxY)
        }
    }

    /// True when the candidate overlaps the source on the perpendicular axis
    /// (y-intervals for left/right, x-intervals for up/down).
    func overlapsPerpendicular(
        _ candidate: SpatialRect,
        with source: SpatialRect,
        direction: Direction
    ) -> Bool {
        switch direction {
        case .left, .right: return candidate.yRangesOverlap(with: source)
        case .up, .down: return candidate.xRangesOverlap(with: source)
        }
    }

    /// The absolute center offset on the perpendicular axis.
    func perpendicularCenterOffset(
        _ candidate: SpatialRect,
        relativeTo source: SpatialRect,
        direction: Direction
    ) -> Double {
        switch direction {
        case .left, .right: return abs(candidate.midY - source.midY)
        case .up, .down: return abs(candidate.midX - source.midX)
        }
    }

    /// The full lexicographic score for one candidate.
    func score(
        for candidate: SpatialCandidate,
        relativeTo source: SpatialCandidate,
        direction: Direction
    ) -> Score {
        Score(
            mainAxisGap: mainAxisGap(candidate.frame, relativeTo: source.frame, direction: direction),
            overlapRank: overlapsPerpendicular(candidate.frame, with: source.frame, direction: direction) ? 0 : 1,
            perpendicularCenterOffset: perpendicularCenterOffset(candidate.frame, relativeTo: source.frame, direction: direction),
            minY: candidate.frame.minY,
            minX: candidate.frame.minX,
            traversalIndex: candidate.traversalIndex,
            identifier: candidate.identifier
        )
    }
}
