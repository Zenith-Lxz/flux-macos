import Testing
@testable import FluxCore

// MARK: - Helpers

private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> SpatialRect {
    SpatialRect(x: x, y: y, width: width, height: height)
}

private func candidate(
    _ identifier: String,
    _ frame: SpatialRect,
    region: String? = nil,
    index: Int = 0
) -> SpatialCandidate {
    SpatialCandidate(
        identifier: identifier,
        frame: frame,
        regionIdentifier: region,
        traversalIndex: index
    )
}

/// Compile-time proof that the argument conforms to `Sendable`.
private func requireSendable<T: Sendable>(_ value: T) {}

// MARK: - Model conformance and geometry

struct SpatialModelTests {
    @Test func spatialRectEqualityAndHash() {
        #expect(rect(1, 2, 3, 4) == rect(1, 2, 3, 4))
        #expect(rect(1, 2, 3, 4) != rect(1, 2, 3, 5))
        #expect(rect(1, 2, 3, 4) != rect(1, 2, 4, 4))
        #expect(Set([rect(1, 2, 3, 4), rect(1, 2, 3, 4)]).count == 1)
        #expect(Set([rect(1, 2, 3, 4), rect(1, 2, 3, 5)]).count == 2)
    }

    @Test func spatialRectGeometryProperties() {
        let r = rect(10, 20, 30, 40)
        #expect(r.minX == 10)
        #expect(r.minY == 20)
        #expect(r.maxX == 40)
        #expect(r.maxY == 60)
        #expect(r.midX == 25)
        #expect(r.midY == 40)
        #expect(r.isValid)
    }

    @Test func spatialRectValidity() {
        #expect(rect(0, 0, 10, 10).isValid)
        #expect(!rect(0, 0, 0, 10).isValid)
        #expect(!rect(0, 0, 10, 0).isValid)
        #expect(!rect(0, 0, -10, 10).isValid)
        #expect(!rect(0, 0, 10, -10).isValid)
        #expect(!rect(.nan, 0, 10, 10).isValid)
        #expect(!rect(0, .nan, 10, 10).isValid)
        #expect(!rect(0, 0, .infinity, 10).isValid)
        #expect(!rect(0, 0, 10, -.infinity).isValid)
    }

    @Test func spatialRectDerivedBoundsOverflowValidity() {
        // Finite stored components can still overflow the derived bounds:
        // x + width and y + height exceed the largest finite Double, so
        // maxX/maxY/midX/midY become infinity.
        #expect(!rect(.greatestFiniteMagnitude, 0, .greatestFiniteMagnitude, 10).isValid)
        #expect(!rect(.greatestFiniteMagnitude, 0, 1e300, 10).isValid)
        #expect(!rect(0, .greatestFiniteMagnitude, 10, .greatestFiniteMagnitude).isValid)
        #expect(!rect(0, .greatestFiniteMagnitude, 10, 1e300).isValid)
    }

    @Test func veryLargeFiniteRectsRemainValid() {
        // 1e300-scale frames keep every derived bound finite and selectable.
        let large = rect(1e300, 1e300, 1e300, 1e300)
        #expect(large.isValid)
        #expect(large.maxX.isFinite)
        #expect(large.maxY.isFinite)
        #expect(large.midX.isFinite)
        #expect(large.midY.isFinite)

        let source = candidate("source", large)
        let target = candidate("target", rect(3e300, 1e300, 1e300, 1e300), index: 1)
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: source, candidates: [target], direction: .right) == target)
    }

    @Test func spatialRectOverlapHelpers() {
        // y-interval overlap (vertical alignment), perpendicular for left/right.
        #expect(rect(0, 0, 10, 10).yRangesOverlap(with: rect(0, 5, 10, 10)))
        #expect(!rect(0, 0, 10, 10).yRangesOverlap(with: rect(0, 10, 10, 10)))
        #expect(!rect(0, 0, 10, 10).yRangesOverlap(with: rect(0, 20, 10, 10)))
        // x-interval overlap (horizontal alignment), perpendicular for up/down.
        #expect(rect(0, 0, 10, 10).xRangesOverlap(with: rect(5, 0, 10, 10)))
        #expect(!rect(0, 0, 10, 10).xRangesOverlap(with: rect(10, 0, 10, 10)))
        #expect(!rect(0, 0, 10, 10).xRangesOverlap(with: rect(20, 0, 10, 10)))
    }

    @Test func spatialCandidateEqualityCoversAllFields() {
        let base = candidate("a", rect(0, 0, 1, 1), region: "r", index: 2)
        #expect(base == candidate("a", rect(0, 0, 1, 1), region: "r", index: 2))
        #expect(base != candidate("b", rect(0, 0, 1, 1), region: "r", index: 2))
        #expect(base != candidate("a", rect(0, 0, 2, 1), region: "r", index: 2))
        #expect(base != candidate("a", rect(0, 0, 1, 1), region: nil, index: 2))
        #expect(base != candidate("a", rect(0, 0, 1, 1), region: "r", index: 3))
        #expect(Set([base, candidate("a", rect(0, 0, 1, 1), region: "r", index: 2)]).count == 1)
    }
}

// MARK: - Direction and half-plane

struct SpatialNavigatorDirectionTests {
    @Test func selectsCandidateInEachDirection() {
        let source = candidate("source", rect(0, 0, 10, 10))
        let right = candidate("right", rect(20, 0, 10, 10), index: 1)
        let left = candidate("left", rect(-20, 0, 10, 10), index: 2)
        let up = candidate("up", rect(0, 20, 10, 10), index: 3)
        let down = candidate("down", rect(0, -20, 10, 10), index: 4)
        let all = [right, left, up, down]
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: source, candidates: all, direction: .right) == right)
        #expect(navigator.select(from: source, candidates: all, direction: .left) == left)
        #expect(navigator.select(from: source, candidates: all, direction: .up) == up)
        #expect(navigator.select(from: source, candidates: all, direction: .down) == down)
    }

    @Test func centerHalfPlaneExcludesCandidates() {
        let source = candidate("source", rect(0, 0, 10, 10))
        // Center (midX 0) is left of the source center; the frame overlaps
        // the source but the candidate is never selectable going right.
        let leftCentered = candidate("leftCentered", rect(-10, 0, 20, 10))
        // Center equals the source center; excluded from both sides.
        let sameCenter = candidate("sameCenter", rect(-5, 0, 20, 10))
        let right = candidate("right", rect(20, 0, 10, 10), index: 1)
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: source, candidates: [leftCentered, sameCenter, right], direction: .right) == right)
        #expect(navigator.select(from: source, candidates: [leftCentered], direction: .right) == nil)
        #expect(navigator.select(from: source, candidates: [sameCenter], direction: .left) == nil)
        #expect(navigator.select(from: source, candidates: [sameCenter], direction: .right) == nil)
    }
}

// MARK: - Scoring

struct SpatialNavigatorScoringTests {
    @Test func nearestMainAxisCandidateWins() {
        let source = candidate("source", rect(0, 0, 10, 10))
        let near = candidate("near", rect(20, 0, 10, 10), index: 1)
        let far = candidate("far", rect(40, 0, 10, 10), index: 2)
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: source, candidates: [far, near], direction: .right) == near)
        let downNear = candidate("downNear", rect(0, -20, 10, 10), index: 1)
        let downFar = candidate("downFar", rect(0, -40, 10, 10), index: 2)
        #expect(navigator.select(from: source, candidates: [downFar, downNear], direction: .down) == downNear)
    }

    @Test func overlapBeatsNonOverlapWhenMainGapEqual() {
        let source = candidate("source", rect(0, 0, 10, 10))
        // Both candidates have gap 0; only the y-aligned one overlaps.
        let overlapping = candidate("overlapping", rect(10, 0, 10, 10), index: 1)
        let separated = candidate("separated", rect(10, 30, 10, 10), index: 2)
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: source, candidates: [separated, overlapping], direction: .right) == overlapping)
        // Vertical counterpart: x-aligned overlap beats a separated frame.
        let verticalOverlap = candidate("verticalOverlap", rect(0, 10, 10, 10), index: 1)
        let verticalSeparated = candidate("verticalSeparated", rect(30, 10, 10, 10), index: 2)
        #expect(navigator.select(from: source, candidates: [verticalSeparated, verticalOverlap], direction: .up) == verticalOverlap)
    }

    @Test func smallerPerpendicularCenterOffsetWins() {
        let source = candidate("source", rect(0, 0, 10, 10))
        // Both overlap on y and share gap 0; the aligned center wins.
        let aligned = candidate("aligned", rect(10, 0, 10, 10), index: 1)
        let offset = candidate("offset", rect(10, 4, 10, 10), index: 2)
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: source, candidates: [offset, aligned], direction: .right) == aligned)
        // Vertical variant: both x-overlap; the centered frame wins going up.
        let verticalAligned = candidate("verticalAligned", rect(0, 10, 10, 10), index: 1)
        let verticalOffset = candidate("verticalOffset", rect(2, 10, 10, 10), index: 2)
        #expect(navigator.select(from: source, candidates: [verticalOffset, verticalAligned], direction: .up) == verticalAligned)
    }

    @Test func overlappingMainAxisFramesWithDistinctCenters() {
        let source = candidate("source", rect(0, 0, 10, 10))
        let navigator = SpatialNavigator()
        // Frame overlaps the source on X (x -2..8) but its center (midX 3)
        // is left of the source center: excluded for `.right`.
        let leftCentered = candidate("leftCentered", rect(-2, 0, 10, 10))
        let rightGap = candidate("rightGap", rect(20, 0, 10, 10), index: 1)
        #expect(navigator.select(from: source, candidates: [leftCentered, rightGap], direction: .right) == rightGap)
        // Frame overlaps on X (x 2..14) with center right (midX 8): eligible
        // with a clamped gap of 0, beating the gapped candidate.
        let overlappingRight = candidate("overlappingRight", rect(2, 0, 12, 10), index: 1)
        let gapped = candidate("gapped", rect(20, 0, 10, 10), index: 2)
        #expect(navigator.select(from: source, candidates: [gapped, overlappingRight], direction: .right) == overlappingRight)
        // Vertical counterpart: y-overlapping frame with center above
        // (midY 8 > 5) wins with a clamped gap.
        let overlappingUp = candidate("overlappingUp", rect(0, 2, 10, 12), index: 1)
        let gappedUp = candidate("gappedUp", rect(0, 20, 10, 10), index: 2)
        #expect(navigator.select(from: source, candidates: [gappedUp, overlappingUp], direction: .up) == overlappingUp)
        // Equal center (midX 5) is excluded even though the frame reaches
        // into the target half-plane.
        let sameCenterX = candidate("sameCenterX", rect(-5, 0, 20, 10))
        #expect(navigator.select(from: source, candidates: [sameCenterX, rightGap], direction: .right) == rightGap)
    }
}

// MARK: - Region clustering

struct SpatialNavigatorRegionTests {
    @Test func sameRegionCandidateBeatsCloserDifferentRegion() {
        let source = candidate("source", rect(0, 0, 10, 10), region: "sidebar")
        let farSameRegion = candidate("farSame", rect(50, 0, 10, 10), region: "sidebar", index: 1)
        let closeOtherRegion = candidate("closeOther", rect(15, 0, 10, 10), region: "content", index: 2)
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: source, candidates: [closeOtherRegion, farSameRegion], direction: .right) == farSameRegion)
    }

    @Test func leavesRegionWhenNoSameRegionTarget() {
        let source = candidate("source", rect(0, 0, 10, 10), region: "sidebar")
        let close = candidate("close", rect(15, 0, 10, 10), region: "content", index: 1)
        let far = candidate("far", rect(50, 0, 10, 10), region: "content", index: 2)
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: source, candidates: [far, close], direction: .right) == close)
    }

    @Test func nilSourceRegionDoesNotCluster() {
        let source = candidate("source", rect(0, 0, 10, 10))
        let nearOther = candidate("nearOther", rect(15, 0, 10, 10), region: "content", index: 1)
        let farSame = candidate("farSame", rect(50, 0, 10, 10), region: nil, index: 2)
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: source, candidates: [farSame, nearOther], direction: .right) == nearOther)
    }

    @Test func mixedRegionClustersOnlyWhenSourceRegionExists() {
        let source = candidate("source", rect(0, 0, 10, 10), region: "sidebar")
        let nearOther = candidate("nearOther", rect(15, 0, 10, 10), region: "content", index: 1)
        let farSame = candidate("farSame", rect(50, 0, 10, 10), region: "sidebar", index: 2)
        let navigator = SpatialNavigator()
        // Same-region exists -> only it competes, ignoring the nearer one.
        #expect(navigator.select(from: source, candidates: [nearOther, farSame], direction: .right) == farSame)
        // Without the same-region candidate, scoring falls back to all.
        #expect(navigator.select(from: source, candidates: [nearOther], direction: .right) == nearOther)
    }
}

// MARK: - Exclusion and empty inputs

struct SpatialNavigatorExclusionTests {
    @Test func sourceItselfIsExcluded() {
        let source = candidate("source", rect(0, 0, 10, 10))
        let duplicate = candidate("source", rect(0, 0, 10, 10))
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: source, candidates: [duplicate], direction: .right) == nil)
        // A re-listed entry with the same identifier but a different frame is
        // dropped by identity too.
        let moved = candidate("source", rect(20, 0, 10, 10))
        #expect(navigator.select(from: source, candidates: [moved], direction: .right) == nil)
    }

    @Test func invalidFramesAreExcluded() {
        let source = candidate("source", rect(0, 0, 10, 10))
        let invalid = [
            candidate("nan", rect(.nan, 0, 10, 10), index: 1),
            candidate("inf", rect(0, 0, .infinity, 10), index: 2),
            candidate("negInf", rect(0, 0, 10, -.infinity), index: 3),
            candidate("zeroWidth", rect(20, 0, 0, 10), index: 4),
            candidate("zeroHeight", rect(20, 0, 10, 0), index: 5),
            candidate("negativeWidth", rect(20, 0, -10, 10), index: 6),
            candidate("negativeHeight", rect(20, 0, 10, -10), index: 7),
        ]
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: source, candidates: invalid, direction: .right) == nil)
    }

    @Test func invalidSourceReturnsNil() {
        let target = candidate("target", rect(20, 0, 10, 10))
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: candidate("source", rect(0, 0, 0, 10)), candidates: [target], direction: .right) == nil)
        #expect(navigator.select(from: candidate("source", rect(.nan, 0, 10, 10)), candidates: [target], direction: .right) == nil)
        #expect(navigator.select(from: candidate("source", rect(0, 0, -10, 10)), candidates: [target], direction: .right) == nil)
    }

    @Test func overflowDerivedBoundsCandidatesAreExcluded() {
        let source = candidate("source", rect(0, 0, 10, 10))
        let navigator = SpatialNavigator()
        // Stored components are finite and positive, but the derived right
        // edge / center overflows to infinity; the frame must be treated
        // as invalid and excluded from selection.
        let overflowX = candidate("overflowX", rect(.greatestFiniteMagnitude, 0, .greatestFiniteMagnitude, 10), index: 1)
        let overflowY = candidate("overflowY", rect(0, .greatestFiniteMagnitude, 10, .greatestFiniteMagnitude), index: 2)
        #expect(navigator.select(from: source, candidates: [overflowX], direction: .right) == nil)
        #expect(navigator.select(from: source, candidates: [overflowY], direction: .up) == nil)
        // A valid candidate still wins when overflow frames are present.
        let valid = candidate("valid", rect(20, 0, 10, 10), index: 1)
        #expect(navigator.select(from: source, candidates: [overflowX, valid], direction: .right) == valid)
    }

    @Test func overflowDerivedBoundsSourceReturnsNil() {
        let navigator = SpatialNavigator()
        let leftTarget = candidate("leftTarget", rect(-20, 0, 10, 10))
        let overflowXSource = candidate("source", rect(.greatestFiniteMagnitude, 0, .greatestFiniteMagnitude, 10))
        #expect(navigator.select(from: overflowXSource, candidates: [leftTarget], direction: .left) == nil)
        let downTarget = candidate("downTarget", rect(0, -20, 10, 10))
        let overflowYSource = candidate("source", rect(0, .greatestFiniteMagnitude, 10, .greatestFiniteMagnitude))
        #expect(navigator.select(from: overflowYSource, candidates: [downTarget], direction: .down) == nil)
    }

    @Test func emptyCandidatesReturnNil() {
        let source = candidate("source", rect(0, 0, 10, 10))
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: source, candidates: [], direction: .right) == nil)
    }

    @Test func noEligibleTargetReturnsNil() {
        let source = candidate("source", rect(0, 0, 10, 10))
        let left = candidate("left", rect(-20, 0, 10, 10))
        let navigator = SpatialNavigator()
        #expect(navigator.select(from: source, candidates: [left], direction: .right) == nil)
    }
}

// MARK: - Tie breaks

struct SpatialNavigatorTieBreakTests {
    @Test func coordinateThenTraversalThenIdentifierTieBreaks() {
        let source = candidate("source", rect(0, 0, 10, 10))
        let navigator = SpatialNavigator()

        // Identical geometry and coordinates: traversal index wins.
        let indexLow = candidate("indexLow", rect(10, 0, 10, 10), index: 1)
        let indexHigh = candidate("indexHigh", rect(10, 0, 10, 10), index: 2)
        #expect(navigator.select(from: source, candidates: [indexHigh, indexLow], direction: .right) == indexLow)

        // Identical geometry, coordinates, and traversal: identifier wins.
        let idA = candidate("a", rect(10, 0, 10, 10), index: 7)
        let idB = candidate("b", rect(10, 0, 10, 10), index: 7)
        #expect(navigator.select(from: source, candidates: [idB, idA], direction: .right) == idA)

        // Otherwise-identical scores: lower minY wins (y before x).
        let higherY = candidate("higherY", rect(10, 2, 10, 6), index: 3)
        let lowerY = candidate("lowerY", rect(10, 0, 10, 10), index: 3)
        #expect(navigator.select(from: source, candidates: [higherY, lowerY], direction: .right) == lowerY)

        // Equal minY and every earlier component: lower minX wins going up.
        let widerX = candidate("widerX", rect(0, 10, 10, 10), index: 4)
        let narrowerX = candidate("narrowerX", rect(2, 10, 6, 10), index: 4)
        #expect(navigator.select(from: source, candidates: [narrowerX, widerX], direction: .up) == widerX)
    }

    @Test func shuffledInputYieldsSameSelection() {
        let source = candidate("source", rect(0, 0, 10, 10))
        let navigator = SpatialNavigator()
        let rightCandidates = [
            candidate("a", rect(15, 0, 10, 10), index: 1),
            candidate("b", rect(30, 0, 10, 10), index: 2),
            candidate("c", rect(15, 20, 10, 10), index: 3),
            candidate("d", rect(15, 4, 10, 10), index: 4),
            candidate("e", rect(25, 0, 10, 10), index: 5),
            candidate("f", rect(40, 0, 10, 10), index: 6),
        ]
        let expectedRight = navigator.select(from: source, candidates: rightCandidates, direction: .right)
        #expect(expectedRight == candidate("a", rect(15, 0, 10, 10), index: 1))
        let permutations = [
            rightCandidates,
            rightCandidates.reversed(),
            Array(rightCandidates[3...]) + Array(rightCandidates[0..<3]),
            [rightCandidates[2], rightCandidates[0], rightCandidates[4], rightCandidates[1], rightCandidates[5], rightCandidates[3]],
        ]
        for permutation in permutations {
            #expect(navigator.select(from: source, candidates: permutation, direction: .right) == expectedRight)
        }

        let downCandidates = [
            candidate("a", rect(0, -15, 10, 10), index: 1),
            candidate("b", rect(0, -30, 10, 10), index: 2),
            candidate("c", rect(5, -15, 10, 10), index: 3),
            candidate("d", rect(-20, -15, 10, 10), index: 4),
            candidate("e", rect(0, -40, 10, 10), index: 5),
        ]
        let expectedDown = navigator.select(from: source, candidates: downCandidates, direction: .down)
        #expect(expectedDown == candidate("a", rect(0, -15, 10, 10), index: 1))
        let downPermutations = [
            downCandidates,
            downCandidates.reversed(),
            Array(downCandidates[2...]) + Array(downCandidates[0..<2]),
            [downCandidates[4], downCandidates[1], downCandidates[3], downCandidates[0], downCandidates[2]],
        ]
        for permutation in downPermutations {
            #expect(navigator.select(from: source, candidates: permutation, direction: .down) == expectedDown)
        }
    }
}

// MARK: - Sendable

struct SpatialNavigatorSendableTests {
    @Test func modelsAndNavigatorAreSendable() {
        // Compile-time proof: the helper only accepts Sendable types.
        requireSendable(rect(0, 0, 10, 10))
        requireSendable(candidate("a", rect(0, 0, 10, 10), region: "sidebar", index: 1))
        requireSendable(SpatialNavigator())
        requireSendable(Direction.right)
    }
}
