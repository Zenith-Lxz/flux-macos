import Testing
@testable import FluxCore

// MARK: - Helpers

/// Compile-time proof that the argument conforms to `Sendable`.
private func requireSendable<T: Sendable>(_ value: T) {}

// MARK: - PointerDelta

struct PointerDeltaTests {
    @Test func equalityCoversBothAxes() {
        #expect(PointerDelta(dx: 1, dy: 2) == PointerDelta(dx: 1, dy: 2))
        #expect(PointerDelta(dx: 1, dy: 2) != PointerDelta(dx: 2, dy: 2))
        #expect(PointerDelta(dx: 1, dy: 2) != PointerDelta(dx: 1, dy: 1))
    }

    @Test func hashMatchesEquality() {
        #expect(Set([PointerDelta(dx: 1, dy: 2), PointerDelta(dx: 1, dy: 2)]).count == 1)
        #expect(Set([PointerDelta(dx: 1, dy: 2), PointerDelta(dx: 2, dy: 1)]).count == 2)
    }
}

// MARK: - Defaults

struct PointerMotionProfileDefaultsTests {
    @Test func defaultProfileHasSpecifiedValues() {
        let profile = PointerMotionProfile.default
        #expect(profile.normalStep == 12)
        #expect(profile.acceleratedStep == 24)
        #expect(profile.maximumStep == 48)
        #expect(profile.fastStep == 72)
        #expect(profile.accelerationRepeatThreshold == 4)
        #expect(profile.maximumRepeatThreshold == 12)
        #expect(profile.resetInterval == 0.20)
    }

    @Test func emptyInitEqualsDefault() {
        #expect(PointerMotionProfile() == PointerMotionProfile.default)
    }

    @Test func defaultStateStartsWithZeroRepeatCount() {
        let state = PointerMotionState()
        #expect(state.repeatCount == 0)
        #expect(state.profile == PointerMotionProfile.default)
    }
}

// MARK: - First key down

struct FirstKeyDownTests {
    @Test func firstKeyDownStartsFreshSequenceAtNormalStep() {
        var state = PointerMotionState()
        let delta = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: 1.0)
        #expect(delta == PointerDelta(dx: 12, dy: 0))
        #expect(state.repeatCount == 0)
    }
}

// MARK: - Direction mapping

struct DirectionMappingTests {
    @Test func allFourDirectionsMapExactly() {
        var state = PointerMotionState()
        #expect(
            state.delta(direction: .right, fast: false, isRepeat: false, timestamp: 1.0)
                == PointerDelta(dx: 12, dy: 0))
        #expect(
            state.delta(direction: .left, fast: false, isRepeat: false, timestamp: 2.0)
                == PointerDelta(dx: -12, dy: 0))
        #expect(
            state.delta(direction: .up, fast: false, isRepeat: false, timestamp: 3.0)
                == PointerDelta(dx: 0, dy: 12))
        #expect(
            state.delta(direction: .down, fast: false, isRepeat: false, timestamp: 4.0)
                == PointerDelta(dx: 0, dy: -12))
    }

    @Test func directionsApplyAtEveryTier() {
        func maximumTierDelta(_ direction: Direction) -> PointerDelta {
            var state = PointerMotionState()
            _ = state.delta(direction: direction, fast: false, isRepeat: false, timestamp: 0.0)
            for i in 1...12 {
                _ = state.delta(direction: direction, fast: false, isRepeat: true, timestamp: Double(i) * 0.01)
            }
            #expect(state.repeatCount == 12)
            return state.delta(direction: direction, fast: false, isRepeat: true, timestamp: 0.13)
        }
        #expect(maximumTierDelta(.right) == PointerDelta(dx: 48, dy: 0))
        #expect(maximumTierDelta(.left) == PointerDelta(dx: -48, dy: 0))
        #expect(maximumTierDelta(.up) == PointerDelta(dx: 0, dy: 48))
        #expect(maximumTierDelta(.down) == PointerDelta(dx: 0, dy: -48))
    }
}

// MARK: - Repeat acceleration thresholds

struct RepeatThresholdTests {
    @Test func repeatTiersFreezeAtThresholdBoundaries() {
        var state = PointerMotionState()
        var timestamp = 0.0
        _ = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: timestamp)
        var seen: [PointerDelta] = []
        for i in 1...14 {
            timestamp += 0.01
            seen.append(state.delta(direction: .right, fast: false, isRepeat: true, timestamp: timestamp))
        }
        #expect(state.repeatCount == 14)
        // Repeats #1..#3 (counts 1..3): below acceleration threshold → normal.
        #expect(seen[0] == PointerDelta(dx: 12, dy: 0))
        #expect(seen[1] == PointerDelta(dx: 12, dy: 0))
        #expect(seen[2] == PointerDelta(dx: 12, dy: 0))
        // Repeat #4 (count 4): at acceleration threshold → accelerated.
        #expect(seen[3] == PointerDelta(dx: 24, dy: 0))
        // Repeats up to #11 (counts 4..11): below maximum threshold → accelerated.
        #expect(seen[4] == PointerDelta(dx: 24, dy: 0))
        #expect(seen[10] == PointerDelta(dx: 24, dy: 0))
        // Repeat #12 (count 12): at maximum threshold → maximum.
        #expect(seen[11] == PointerDelta(dx: 48, dy: 0))
        #expect(seen[12] == PointerDelta(dx: 48, dy: 0))
        #expect(seen[13] == PointerDelta(dx: 48, dy: 0))
    }

    @Test func repeatCountIsReadOnlyAndObservable() {
        var state = PointerMotionState()
        _ = state.delta(direction: .down, fast: false, isRepeat: false, timestamp: 0.0)
        _ = state.delta(direction: .down, fast: false, isRepeat: true, timestamp: 0.01)
        #expect(state.repeatCount == 1)
    }
}

// MARK: - Saturating repeat increment

struct SaturatingIncrementTests {
    @Test func ordinaryValuesIncrement() {
        #expect(PointerMotionState.saturatingIncrement(0) == 1)
        #expect(PointerMotionState.saturatingIncrement(1) == 2)
        #expect(PointerMotionState.saturatingIncrement(41) == 42)
        #expect(PointerMotionState.saturatingIncrement(Int.max - 1) == Int.max)
    }

    @Test func maximumValueSaturatesInsteadOfOverflowing() {
        #expect(PointerMotionState.saturatingIncrement(Int.max) == Int.max)
    }
}

// MARK: - Fast (Shift) tier

struct FastTierTests {
    @Test func fastUsesFastStepFromTheFirstEvent() {
        var state = PointerMotionState()
        #expect(
            state.delta(direction: .right, fast: true, isRepeat: false, timestamp: 0.0)
                == PointerDelta(dx: 72, dy: 0))
        #expect(state.repeatCount == 0)
    }

    @Test func fastRepeatContinuesAndUpdatesTheSequence() {
        var state = PointerMotionState()
        _ = state.delta(direction: .right, fast: true, isRepeat: false, timestamp: 0.0)
        #expect(
            state.delta(direction: .right, fast: true, isRepeat: true, timestamp: 0.01)
                == PointerDelta(dx: 72, dy: 0))
        #expect(state.repeatCount == 1)
        for i in 2...20 {
            #expect(
                state.delta(direction: .right, fast: true, isRepeat: true, timestamp: Double(i) * 0.01)
                    == PointerDelta(dx: 72, dy: 0))
        }
        #expect(state.repeatCount == 20)
    }

    @Test func fastRepeatContinuesANormalSequence() {
        var state = PointerMotionState()
        _ = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: 0.0)
        #expect(
            state.delta(direction: .right, fast: true, isRepeat: true, timestamp: 0.01)
                == PointerDelta(dx: 72, dy: 0))
        #expect(state.repeatCount == 1)
    }

    @Test func fastNonRepeatResetsTheSequence() {
        var state = PointerMotionState()
        _ = state.delta(direction: .right, fast: true, isRepeat: false, timestamp: 0.0)
        _ = state.delta(direction: .right, fast: true, isRepeat: true, timestamp: 0.01)
        #expect(state.repeatCount == 1)
        _ = state.delta(direction: .right, fast: true, isRepeat: false, timestamp: 0.02)
        #expect(state.repeatCount == 0)
    }
}

// MARK: - Sequence reset rules

struct SequenceResetTests {
    @Test func nonRepeatResetsRepeatCountAndTier() {
        var state = PointerMotionState()
        var timestamp = 0.0
        _ = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: timestamp)
        for _ in 0..<6 {
            timestamp += 0.01
            _ = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: timestamp)
        }
        #expect(state.repeatCount == 6)
        timestamp += 0.01
        let reset = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: timestamp)
        #expect(reset == PointerDelta(dx: 12, dy: 0))
        #expect(state.repeatCount == 0)
        // The next repeat builds a fresh sequence from the normal tier.
        timestamp += 0.01
        let next = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: timestamp)
        #expect(next == PointerDelta(dx: 12, dy: 0))
        #expect(state.repeatCount == 1)
    }

    @Test func nonRepeatAfterMaximumTierResetsToNormalInAnyNewDirection() {
        for newDirection in Direction.allCases {
            var state = PointerMotionState()
            var timestamp = 0.0
            // Reach the maximum tier (repeat count 12) in a fixed direction.
            _ = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: timestamp)
            for _ in 0..<12 {
                timestamp += 0.01
                _ = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: timestamp)
            }
            #expect(state.repeatCount == 12)
            // A non-repeat starts a fresh sequence at the normal tier (12),
            // regardless of the direction it arrives in.
            timestamp += 0.01
            let delta = state.delta(direction: newDirection, fast: false, isRepeat: false, timestamp: timestamp)
            let expected: PointerDelta
            switch newDirection {
            case .up: expected = PointerDelta(dx: 0, dy: 12)
            case .down: expected = PointerDelta(dx: 0, dy: -12)
            case .left: expected = PointerDelta(dx: -12, dy: 0)
            case .right: expected = PointerDelta(dx: 12, dy: 0)
            }
            #expect(delta == expected)
            #expect(state.repeatCount == 0)
        }
    }

    @Test func directionChangeStartsFresh() {
        var state = PointerMotionState()
        _ = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: 0.0)
        _ = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: 0.01)
        _ = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: 0.02)
        #expect(state.repeatCount == 2)
        let changed = state.delta(direction: .left, fast: false, isRepeat: true, timestamp: 0.03)
        #expect(changed == PointerDelta(dx: -12, dy: 0))
        #expect(state.repeatCount == 0)
        // The new direction can build its own sequence.
        let next = state.delta(direction: .left, fast: false, isRepeat: true, timestamp: 0.04)
        #expect(next == PointerDelta(dx: -12, dy: 0))
        #expect(state.repeatCount == 1)
    }

    @Test func backwardTimestampStartsFresh() {
        var state = PointerMotionState()
        _ = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: 1.0)
        _ = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: 1.05)
        #expect(state.repeatCount == 1)
        let delta = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: 1.04)
        #expect(delta == PointerDelta(dx: 12, dy: 0))
        #expect(state.repeatCount == 0)
    }

    @Test func equalTimestampRepeatIsMonotonicAndContinues() {
        var state = PointerMotionState()
        _ = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: 1.0)
        let delta = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: 1.0)
        #expect(delta == PointerDelta(dx: 12, dy: 0))
        #expect(state.repeatCount == 1)
    }
}

// MARK: - Idle gap boundary

struct IdleGapTests {
    @Test func gapExactlyAtResetIntervalContinues() {
        var state = PointerMotionState()
        _ = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: 0.0)
        let delta = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: 0.2)
        #expect(delta == PointerDelta(dx: 12, dy: 0))
        #expect(state.repeatCount == 1)
    }

    @Test func gapJustOverResetIntervalStartsFresh() {
        var state = PointerMotionState()
        _ = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: 0.0)
        let delta = state.delta(
            direction: .right, fast: false, isRepeat: true,
            timestamp: 0.2 + Double.ulpOfOne)
        #expect(delta == PointerDelta(dx: 12, dy: 0))
        #expect(state.repeatCount == 0)
    }

    @Test func largeGapStartsFresh() {
        var state = PointerMotionState()
        _ = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: 0.0)
        let delta = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: 5.0)
        #expect(delta == PointerDelta(dx: 12, dy: 0))
        #expect(state.repeatCount == 0)
    }
}

// MARK: - Non-finite timestamps

struct NonFiniteTimestampTests {
    @Test func nonFiniteRepeatTimestampsStartFreshWithoutNaNPropagation() {
        for bad in [Double.nan, Double.infinity, -Double.infinity] {
            var state = PointerMotionState()
            let first = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: 1.0)
            #expect(first.dx.isFinite)
            let delta = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: bad)
            #expect(delta == PointerDelta(dx: 12, dy: 0))
            #expect(state.repeatCount == 0)
            // The bad timestamp never anchors a sequence: the next repeat is fresh too.
            let next = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: 1.05)
            #expect(next == PointerDelta(dx: 12, dy: 0))
            #expect(state.repeatCount == 0)
        }
    }

    @Test func nonRepeatWithNonFiniteTimestampStillReturnsValidDelta() {
        var state = PointerMotionState()
        let delta = state.delta(direction: .up, fast: false, isRepeat: false, timestamp: Double.nan)
        #expect(delta == PointerDelta(dx: 0, dy: 12))
        #expect(state.repeatCount == 0)
        #expect(delta.dx.isFinite && delta.dy.isFinite)
    }
}

// MARK: - Reset

struct PointerMotionResetTests {
    @Test func resetClearsDirectionTimestampAndCount() {
        var state = PointerMotionState()
        _ = state.delta(direction: .right, fast: false, isRepeat: false, timestamp: 0.0)
        for i in 1...5 {
            _ = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: Double(i) * 0.01)
        }
        #expect(state.repeatCount == 5)
        state.reset()
        #expect(state.repeatCount == 0)
        // A repeat after reset cannot continue the old sequence.
        let delta = state.delta(direction: .right, fast: false, isRepeat: true, timestamp: 0.06)
        #expect(delta == PointerDelta(dx: 12, dy: 0))
        #expect(state.repeatCount == 0)
    }
}

// MARK: - Custom profile

struct CustomProfileTests {
    @Test func customProfileValuesAreHonored() {
        let profile = PointerMotionProfile(
            normalStep: 3,
            acceleratedStep: 5,
            maximumStep: 9,
            fastStep: 20,
            accelerationRepeatThreshold: 2,
            maximumRepeatThreshold: 4,
            resetInterval: 0.5)
        var state = PointerMotionState(profile: profile)
        #expect(
            state.delta(direction: .down, fast: false, isRepeat: false, timestamp: 0.0)
                == PointerDelta(dx: 0, dy: -3))
        _ = state.delta(direction: .down, fast: false, isRepeat: true, timestamp: 0.1)
        #expect(state.repeatCount == 1)
        // Count 2 is at the acceleration threshold; count 4 is at the maximum.
        #expect(
            state.delta(direction: .down, fast: false, isRepeat: true, timestamp: 0.2)
                == PointerDelta(dx: 0, dy: -5))
        #expect(
            state.delta(direction: .down, fast: false, isRepeat: true, timestamp: 0.3)
                == PointerDelta(dx: 0, dy: -5))
        #expect(
            state.delta(direction: .down, fast: false, isRepeat: true, timestamp: 0.4)
                == PointerDelta(dx: 0, dy: -9))
        #expect(state.repeatCount == 4)
        // Custom reset interval: a gap of exactly 0.5 continues...
        #expect(
            state.delta(direction: .down, fast: false, isRepeat: true, timestamp: 0.9)
                == PointerDelta(dx: 0, dy: -9))
        #expect(state.repeatCount == 5)
        // ...and a gap just over it starts fresh.
        #expect(
            state.delta(direction: .down, fast: false, isRepeat: true, timestamp: 1.41)
                == PointerDelta(dx: 0, dy: -3))
        #expect(state.repeatCount == 0)
    }

    @Test func customFastStepIsUsedAtEveryRepeatCount() {
        let profile = PointerMotionProfile(
            normalStep: 3, acceleratedStep: 5, maximumStep: 9, fastStep: 20,
            accelerationRepeatThreshold: 2, maximumRepeatThreshold: 4)
        var state = PointerMotionState(profile: profile)
        _ = state.delta(direction: .left, fast: true, isRepeat: false, timestamp: 0.0)
        for i in 1...6 {
            #expect(
                state.delta(direction: .left, fast: true, isRepeat: true, timestamp: Double(i) * 0.01)
                    == PointerDelta(dx: -20, dy: 0))
        }
    }
}

// MARK: - Invalid profile sanitization

struct InvalidProfileSanitizationTests {
    @Test func allInvalidValuesFallBackToDefaults() {
        let profile = PointerMotionProfile(
            normalStep: -1,
            acceleratedStep: 0,
            maximumStep: .infinity,
            fastStep: .nan,
            accelerationRepeatThreshold: -3,
            maximumRepeatThreshold: -7,
            resetInterval: -0.1)
        #expect(profile == PointerMotionProfile.default)
    }

    @Test func individuallyInvalidValuesUsePerFieldDefaults() {
        let profile = PointerMotionProfile(
            normalStep: .nan,
            acceleratedStep: 0,
            maximumStep: 100,
            fastStep: 40,
            accelerationRepeatThreshold: 6,
            maximumRepeatThreshold: -2,
            resetInterval: .infinity)
        #expect(profile.normalStep == 12)
        #expect(profile.acceleratedStep == 24)
        #expect(profile.maximumStep == 100)
        #expect(profile.fastStep == 40)
        #expect(profile.accelerationRepeatThreshold == 6)
        #expect(profile.maximumRepeatThreshold == 12)
        #expect(profile.resetInterval == 0.20)
    }

    @Test func maximumThresholdIsRaisedToAccelerationThreshold() {
        let profile = PointerMotionProfile(
            accelerationRepeatThreshold: 8, maximumRepeatThreshold: 2)
        #expect(profile.accelerationRepeatThreshold == 8)
        #expect(profile.maximumRepeatThreshold == 8)
    }

    @Test func negativeAccelerationThresholdClampsMaximumUp() {
        let profile = PointerMotionProfile(
            accelerationRepeatThreshold: -1, maximumRepeatThreshold: 2)
        #expect(profile.accelerationRepeatThreshold == 4)
        #expect(profile.maximumRepeatThreshold == 4)
    }

    @Test func sanitizedProfilesRemainWellFormed() {
        let profiles = [
            PointerMotionProfile(normalStep: 0),
            PointerMotionProfile(normalStep: .nan),
            PointerMotionProfile(normalStep: -5),
            PointerMotionProfile(acceleratedStep: 0),
            PointerMotionProfile(maximumStep: .infinity),
            PointerMotionProfile(fastStep: .nan),
            PointerMotionProfile(resetInterval: 0),
            PointerMotionProfile(accelerationRepeatThreshold: -1),
            PointerMotionProfile(maximumRepeatThreshold: -1),
            PointerMotionProfile(accelerationRepeatThreshold: 10, maximumRepeatThreshold: 1),
        ]
        for profile in profiles {
            #expect(profile.normalStep > 0 && profile.normalStep.isFinite)
            #expect(profile.acceleratedStep > 0 && profile.acceleratedStep.isFinite)
            #expect(profile.maximumStep > 0 && profile.maximumStep.isFinite)
            #expect(profile.fastStep > 0 && profile.fastStep.isFinite)
            #expect(profile.resetInterval > 0 && profile.resetInterval.isFinite)
            #expect(profile.accelerationRepeatThreshold >= 0)
            #expect(profile.maximumRepeatThreshold >= profile.accelerationRepeatThreshold)
        }
    }

    @Test func invalidProfileConstructionIsDeterministic() {
        let a = PointerMotionProfile(normalStep: .nan, acceleratedStep: -3, maximumStep: 0)
        let b = PointerMotionProfile(normalStep: .nan, acceleratedStep: -3, maximumStep: 0)
        #expect(a == b)
    }
}

// MARK: - Conformance and determinism

struct ConformanceAndDeterminismTests {
    @Test func allTypesAreSendable() {
        requireSendable(PointerDelta(dx: 1, dy: 2))
        requireSendable(PointerMotionProfile())
        requireSendable(PointerMotionState())
    }

    @Test func identicalInputsProduceIdenticalSequences() {
        func run() -> [PointerDelta] {
            var state = PointerMotionState()
            var result: [PointerDelta] = []
            var timestamp = 0.0
            result.append(state.delta(direction: .up, fast: false, isRepeat: false, timestamp: timestamp))
            for _ in 0..<8 {
                timestamp += 0.01
                result.append(state.delta(direction: .up, fast: false, isRepeat: true, timestamp: timestamp))
            }
            return result
        }
        #expect(run() == run())
    }
}
