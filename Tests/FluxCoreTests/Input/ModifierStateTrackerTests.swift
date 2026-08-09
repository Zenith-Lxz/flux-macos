import Testing
@testable import FluxCore

@Suite("Modifier state tracker")
struct ModifierStateTrackerTests {
    @Test("left and right sides remain independent across aggregate flag changes")
    func independentSides() {
        var tracker = ModifierStateTracker()

        let leftDown = tracker.transition(for: .leftShift, aggregateIsActive: true)
        #expect(leftDown?.isDown == true)
        #expect(leftDown?.modifiers == [.leftShift])

        let rightDown = tracker.transition(for: .rightShift, aggregateIsActive: true)
        #expect(rightDown?.isDown == true)
        #expect(rightDown?.modifiers == [.leftShift, .rightShift])

        let leftUp = tracker.transition(for: .leftShift, aggregateIsActive: true)
        #expect(leftUp?.isDown == false)
        #expect(leftUp?.modifiers == [.rightShift])

        let rightUp = tracker.transition(for: .rightShift, aggregateIsActive: false)
        #expect(rightUp?.isDown == false)
        #expect(rightUp?.modifiers.isEmpty == true)
    }

    @Test("all physical modifier keys map to their matching sided bit")
    func allSidedModifiers() {
        let cases: [(PhysicalKey, KeyModifiers)] = [
            (.leftControl, .leftControl),
            (.rightControl, .rightControl),
            (.leftCommand, .leftCommand),
            (.rightCommand, .rightCommand),
            (.leftOption, .leftOption),
            (.rightOption, .rightOption),
            (.leftShift, .leftShift),
            (.rightShift, .rightShift),
        ]

        for (key, expected) in cases {
            var tracker = ModifierStateTracker()
            let transition = tracker.transition(for: key, aggregateIsActive: true)
            #expect(transition?.isDown == true)
            #expect(transition?.modifiers == expected)
        }
    }

    @Test("aggregate-off ghost release stays released")
    func ghostRelease() {
        var tracker = ModifierStateTracker()

        let transition = tracker.transition(for: .leftCommand, aggregateIsActive: false)

        #expect(transition?.isDown == false)
        #expect(transition?.modifiers.isEmpty == true)
        #expect(tracker.modifiers.isEmpty)
    }

    @Test("unknown keys do not mutate modifier state")
    func unknownKey() {
        var tracker = ModifierStateTracker()
        _ = tracker.transition(for: .leftOption, aggregateIsActive: true)

        let transition = tracker.transition(for: .a, aggregateIsActive: true)

        #expect(transition == nil)
        #expect(tracker.modifiers == [.leftOption])
    }

    @Test("reset clears every tracked side")
    func reset() {
        var tracker = ModifierStateTracker()
        _ = tracker.transition(for: .leftControl, aggregateIsActive: true)
        _ = tracker.transition(for: .rightCommand, aggregateIsActive: true)

        tracker.reset()

        #expect(tracker.modifiers.isEmpty)
    }
}
