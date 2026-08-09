import Testing
@testable import FluxCore

// MARK: - Helpers

/// Compile-time proof that the argument conforms to `Sendable`.
private func requireSendable<T: Sendable>(_ value: T) {}

/// A candidate whose frame center lands exactly on `(centerX, centerY)`
/// using integer-friendly 10x10 frames.
private func centerCandidate(
    _ identifier: String,
    centerX: Double,
    centerY: Double,
    depth: Int
) -> PointerSnapCandidate {
    PointerSnapCandidate(
        identifier: identifier,
        frame: PointerSnapFrame(
            x: centerX - 5,
            y: centerY - 5,
            width: 10,
            height: 10
        ),
        depth: depth
    )
}

// MARK: - Geometry validation

struct PointerSnapFrameValidationTests {
    @Test func validFrameReportsCentersAndValidity() {
        let frame = PointerSnapFrame(x: 10, y: 20, width: 30, height: 40)
        #expect(frame.isValid)
        #expect(frame.midX == 25)
        #expect(frame.midY == 40)
    }

    @Test func zeroOrNegativeSizeIsInvalid() {
        #expect(!PointerSnapFrame(x: 0, y: 0, width: 0, height: 10).isValid)
        #expect(!PointerSnapFrame(x: 0, y: 0, width: 10, height: 0).isValid)
        #expect(!PointerSnapFrame(x: 0, y: 0, width: -10, height: 10).isValid)
        #expect(!PointerSnapFrame(x: 0, y: 0, width: 10, height: -10).isValid)
    }

    @Test func nonFiniteComponentsAreInvalid() {
        #expect(!PointerSnapFrame(x: .nan, y: 0, width: 10, height: 10).isValid)
        #expect(!PointerSnapFrame(x: 0, y: .infinity, width: 10, height: 10).isValid)
        #expect(!PointerSnapFrame(x: 0, y: 0, width: .nan, height: 10).isValid)
        #expect(!PointerSnapFrame(x: 0, y: 0, width: 10, height: -Double.infinity).isValid)
    }

    @Test func derivedCenterOverflowIsInvalid() {
        // Stored components are finite, but x + width/2 overflows to
        // infinity; the frame must not be admitted into selection.
        #expect(!PointerSnapFrame(x: 1e308, y: 0, width: 1.6e308, height: 10).isValid)
    }

    @Test func derivedEdgeOverflowIsInvalidEvenWhenCenterIsFinite() {
        #expect(!PointerSnapFrame(x: 1e308, y: 0, width: 1e308, height: 10).isValid)
        #expect(!PointerSnapFrame(x: 0, y: 1e308, width: 10, height: 1e308).isValid)
    }

    @Test func pointValidityRequiresFiniteCoordinates() {
        #expect(PointerSnapPoint(x: 1, y: 2).isValid)
        #expect(!PointerSnapPoint(x: .nan, y: 2).isValid)
        #expect(!PointerSnapPoint(x: 1, y: .infinity).isValid)
        #expect(!PointerSnapPoint(x: -Double.infinity, y: 0).isValid)
    }
}

// MARK: - Policy sanitization

struct PointerSnapPolicyTests {
    @Test func defaultPolicyHasSpecifiedValues() {
        let policy = PointerSnapPolicy.default
        #expect(policy.radius == 32)
        #expect(policy.maxDepth == 3)
    }

    @Test func emptyInitEqualsDefault() {
        #expect(PointerSnapPolicy() == PointerSnapPolicy.default)
    }

    @Test func invalidRadiusFallsBackToDefault() {
        for bad in [Double.nan, Double.infinity, -Double.infinity, 0, -5] {
            #expect(PointerSnapPolicy(radius: bad).radius == 32)
        }
    }

    @Test func negativeMaxDepthFallsBackToDefault() {
        #expect(PointerSnapPolicy(maxDepth: -1).maxDepth == 3)
        #expect(PointerSnapPolicy(maxDepth: 0).maxDepth == 0)
    }

    @Test func customValuesAreHonored() {
        let policy = PointerSnapPolicy(radius: 16, maxDepth: 1)
        #expect(policy.radius == 16)
        #expect(policy.maxDepth == 1)
    }

    @Test func radiusAndDepthNeverExceedTheSafetyBounds() {
        let policy = PointerSnapPolicy(radius: 10_000, maxDepth: Int.max)
        #expect(policy.radius == 32)
        #expect(policy.maxDepth == 3)
    }
}

// MARK: - Radius boundary

struct RadiusBoundaryTests {
    @Test func exactRadiusBoundaryAccepts() {
        // Center exactly 32pt from the geometric target (axis aligned,
        // integer-exact): accepted.
        let target = PointerSnapPoint(x: 100, y: 100)
        let policy = PointerSnapPolicy(radius: 32, maxDepth: 3)
        let atBoundary = centerCandidate("a", centerX: 132, centerY: 100, depth: 0)
        #expect(
            PointerSnapSelector().select(from: [atBoundary], target: target, policy: policy)?.identifier
                == "a"
        )
    }

    @Test func justOutsideRadiusRejects() {
        // Center 33pt away (integer-exact, one step over): rejected.
        let target = PointerSnapPoint(x: 100, y: 100)
        let policy = PointerSnapPolicy(radius: 32, maxDepth: 3)
        let outside = centerCandidate("a", centerX: 133, centerY: 100, depth: 0)
        #expect(PointerSnapSelector().select(from: [outside], target: target, policy: policy) == nil)
    }

    @Test func insideRadiusAccepts() {
        let target = PointerSnapPoint(x: 100, y: 100)
        let inside = centerCandidate("a", centerX: 110, centerY: 105, depth: 0)
        #expect(PointerSnapSelector().select(from: [inside], target: target)?.identifier == "a")
    }

    @Test func diagonalDistanceUsesEuclideanRule() {
        // A 3-4-5 triangle: distance exactly 5 from the origin. Radius 5
        // accepts it; radius just below (via center (4,4), distance ~5.657)
        // rejects.
        let target = PointerSnapPoint(x: 0, y: 0)
        let policy = PointerSnapPolicy(radius: 5, maxDepth: 3)
        let atDistance = centerCandidate("a", centerX: 3, centerY: 4, depth: 0)
        #expect(
            PointerSnapSelector().select(from: [atDistance], target: target, policy: policy)?.identifier
                == "a"
        )
        let outside = centerCandidate("b", centerX: 4, centerY: 4, depth: 0)
        #expect(PointerSnapSelector().select(from: [outside], target: target, policy: policy) == nil)
    }
}

// MARK: - Nearest-center selection

struct NearestCenterTests {
    @Test func nearestCenterWinsRegardlessOfInputOrder() {
        let target = PointerSnapPoint(x: 0, y: 0)
        let near = centerCandidate("near", centerX: 10, centerY: 0, depth: 0)
        let far = centerCandidate("far", centerX: 30, centerY: 0, depth: 0)
        #expect(PointerSnapSelector().select(from: [near, far], target: target)?.identifier == "near")
        #expect(PointerSnapSelector().select(from: [far, near], target: target)?.identifier == "near")
    }

    @Test func equalDistancePrefersShallowerDepth() {
        // Both centers are exactly 5 from the origin (mirrored 3-4-5
        // triangles); the element closest to the pointer (depth 0) wins
        // over its ancestor (depth 1), regardless of input order.
        let target = PointerSnapPoint(x: 0, y: 0)
        let deep = centerCandidate("deep", centerX: 3, centerY: 4, depth: 1)
        let shallow = centerCandidate("shallow", centerX: 4, centerY: 3, depth: 0)
        #expect(PointerSnapSelector().select(from: [deep, shallow], target: target)?.identifier == "shallow")
        #expect(PointerSnapSelector().select(from: [shallow, deep], target: target)?.identifier == "shallow")
    }

    @Test func equalDistanceAndDepthPrefersLexicographicIdentifier() {
        let target = PointerSnapPoint(x: 0, y: 0)
        let b = centerCandidate("b", centerX: 3, centerY: 4, depth: 0)
        let a = centerCandidate("a", centerX: 4, centerY: 3, depth: 0)
        #expect(PointerSnapSelector().select(from: [a, b], target: target)?.identifier == "a")
        #expect(PointerSnapSelector().select(from: [b, a], target: target)?.identifier == "a")
    }
}

// MARK: - Depth bound and empty/invalid inputs

struct DepthAndEmptyTests {
    @Test func deeperThanPolicyIsIgnored() {
        let target = PointerSnapPoint(x: 0, y: 0)
        let policy = PointerSnapPolicy(radius: 32, maxDepth: 3)
        let depth4 = centerCandidate("too-deep", centerX: 0, centerY: 0, depth: 4)
        #expect(PointerSnapSelector().select(from: [depth4], target: target, policy: policy) == nil)
        let depth3 = centerCandidate("ok", centerX: 0, centerY: 0, depth: 3)
        #expect(
            PointerSnapSelector().select(from: [depth3], target: target, policy: policy)?.identifier
                == "ok"
        )
    }

    @Test func negativeDepthIsIgnored() {
        let target = PointerSnapPoint(x: 0, y: 0)
        let bad = centerCandidate("bad", centerX: 0, centerY: 0, depth: -1)
        #expect(PointerSnapSelector().select(from: [bad], target: target) == nil)
    }

    @Test func emptyCandidatesReturnNil() {
        #expect(PointerSnapSelector().select(from: [], target: PointerSnapPoint(x: 0, y: 0)) == nil)
    }

    @Test func invalidTargetReturnsNil() {
        for bad in [Double.nan, Double.infinity, -Double.infinity] {
            let target = PointerSnapPoint(x: bad, y: 0)
            let candidate = centerCandidate("a", centerX: 0, centerY: 0, depth: 0)
            #expect(PointerSnapSelector().select(from: [candidate], target: target) == nil)
        }
    }
}

// MARK: - Invalid and overflowing geometry

struct InvalidGeometryTests {
    @Test func invalidFramesAreIgnored() {
        let target = PointerSnapPoint(x: 0, y: 0)
        let invalidFrames = [
            PointerSnapFrame(x: 0, y: 0, width: 0, height: 10),
            PointerSnapFrame(x: 0, y: 0, width: 10, height: -5),
            PointerSnapFrame(x: .nan, y: 0, width: 10, height: 10),
            PointerSnapFrame(x: 0, y: 0, width: .infinity, height: 10),
            PointerSnapFrame(x: 1e308, y: 0, width: 1.6e308, height: 10),
        ]
        for frame in invalidFrames {
            let candidate = PointerSnapCandidate(identifier: "bad", frame: frame, depth: 0)
            #expect(PointerSnapSelector().select(from: [candidate], target: target) == nil)
        }
    }

    @Test func overflowingDistanceIsIgnoredNotSelected() {
        // Finite components, but the center distance squared overflows to
        // infinity; the candidate must be ignored, never crash or win.
        let target = PointerSnapPoint(x: 0, y: 0)
        let huge = centerCandidate("huge", centerX: 1e200, centerY: 1e200, depth: 0)
        let near = centerCandidate("near", centerX: 10, centerY: 0, depth: 0)
        #expect(PointerSnapSelector().select(from: [huge, near], target: target)?.identifier == "near")
        #expect(PointerSnapSelector().select(from: [huge], target: target) == nil)
    }

    @Test func oneInvalidCandidateDoesNotPoisonValidOnes() {
        let target = PointerSnapPoint(x: 0, y: 0)
        let invalid = PointerSnapCandidate(
            identifier: "invalid",
            frame: PointerSnapFrame(x: .nan, y: 0, width: 10, height: 10),
            depth: 0
        )
        let valid = centerCandidate("valid", centerX: 8, centerY: 0, depth: 0)
        #expect(PointerSnapSelector().select(from: [invalid, valid], target: target)?.identifier == "valid")
    }
}

// MARK: - Conformance and determinism

struct SnapConformanceTests {
    @Test func allTypesAreSendable() {
        requireSendable(PointerSnapPoint(x: 0, y: 0))
        requireSendable(PointerSnapFrame(x: 0, y: 0, width: 1, height: 1))
        requireSendable(
            PointerSnapCandidate(
                identifier: "a",
                frame: PointerSnapFrame(x: 0, y: 0, width: 1, height: 1),
                depth: 0
            )
        )
        requireSendable(PointerSnapPolicy())
        requireSendable(PointerSnapSelector())
    }

    @Test func valueTypesAreEquatableAndHashable() {
        let pointA = PointerSnapPoint(x: 1, y: 2)
        let pointB = PointerSnapPoint(x: 1, y: 2)
        let pointC = PointerSnapPoint(x: 2, y: 2)
        #expect(pointA == pointB)
        #expect(pointA != pointC)
        #expect(Set([pointA, pointB, pointC]).count == 2)

        let frameA = PointerSnapFrame(x: 0, y: 0, width: 10, height: 10)
        let frameB = PointerSnapFrame(x: 0, y: 0, width: 10, height: 10)
        #expect(frameA == frameB)
        #expect(Set([frameA, frameB]).count == 1)

        let candidateA = PointerSnapCandidate(identifier: "x", frame: frameA, depth: 0)
        let candidateB = PointerSnapCandidate(identifier: "x", frame: frameB, depth: 0)
        let candidateC = PointerSnapCandidate(identifier: "y", frame: frameA, depth: 0)
        #expect(candidateA == candidateB)
        #expect(candidateA != candidateC)
    }

    @Test func identicalInputsProduceIdenticalSelections() {
        func run() -> String? {
            PointerSnapSelector().select(
                from: [
                    centerCandidate("a", centerX: 10, centerY: 2, depth: 0),
                    centerCandidate("b", centerX: 6, centerY: 8, depth: 1),
                    centerCandidate("c", centerX: 20, centerY: 0, depth: 2),
                ],
                target: PointerSnapPoint(x: 0, y: 0)
            )?.identifier
        }
        #expect(run() == run())
    }
}
