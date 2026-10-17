import Foundation
import PressyCore
import Testing

/// Collects scheduled work so tests decide when the sequence gap "elapses".
@MainActor
final class FakeScheduler {
    private(set) var pending: [(delay: TimeInterval, work: @MainActor () -> Void, cancelled: Bool)] = []

    var schedule: PatternRecognizer.Schedule {
        { [unowned self] delay, work in
            pending.append((delay, work, false))
            let index = pending.count - 1
            return { [unowned self] in pending[index].cancelled = true }
        }
    }

    var active: Int { pending.filter { !$0.cancelled }.count }

    func elapse() {
        let due = pending.indices.filter { !pending[$0].cancelled }
        for index in due {
            pending[index].cancelled = true
            pending[index].work()
        }
    }
}

@MainActor
struct PatternRecognizerTests {
    let scheduler = FakeScheduler()
    var emitted: [String] { box.values }
    private let box = Box()

    final class Box { var values: [String] = [] }

    func recognizer(_ known: Set<String>, timing: PressTiming = PressTiming(longPress: 0.5, sequenceGap: 0.4)) -> PatternRecognizer {
        let box = self.box
        return PatternRecognizer(timing: timing, knownPatterns: known, schedule: scheduler.schedule) { box.values.append($0) }
    }

    func press(_ r: PatternRecognizer, at t: TimeInterval, for duration: TimeInterval) {
        r.buttonDown(at: t)
        r.buttonUp(at: t + duration)
    }

    @Test func shortPressWaitsForGapWhenADoubleIsMapped() {
        let r = recognizer([".", ".."])
        press(r, at: 0, for: 0.18)
        #expect(emitted.isEmpty)
        #expect(scheduler.pending.last?.delay == 0.4)
        scheduler.elapse()
        #expect(emitted == ["."])
    }

    @Test func doublePressEmitsAtOnceWhenNothingLongerIsMapped() {
        let r = recognizer([".", ".."])
        press(r, at: 0, for: 0.1)
        press(r, at: 0.25, for: 0.17)
        #expect(emitted == [".."])
        #expect(scheduler.active == 0)
    }

    @Test func longPressThresholdIsInclusive() {
        let r = recognizer(["-", "."])
        press(r, at: 0, for: 0.5)
        #expect(emitted == ["-"])
        press(r, at: 2, for: 0.499)
        #expect(emitted == ["-", "."])
    }

    @Test func combinationOfShortAndLong() {
        let r = recognizer([".", ".-", ".-."])
        press(r, at: 0, for: 0.1)
        press(r, at: 0.3, for: 1.2)
        #expect(emitted.isEmpty)
        scheduler.elapse()
        #expect(emitted == [".-"])
    }

    @Test func unmappedPatternIsEmittedImmediatelyAtADeadEnd() {
        let r = recognizer([".."])
        press(r, at: 0, for: 0.9)
        #expect(emitted == ["-"])
    }

    @Test func duplicateEdgesAreIgnored() {
        let r = recognizer(["."])
        r.buttonDown(at: 0)
        r.buttonDown(at: 0.01)
        r.buttonUp(at: 0.2)
        r.buttonUp(at: 0.21)
        r.buttonUp(at: 0.3)
        #expect(emitted == ["."])
    }

    @Test func newPressCancelsThePendingGap() {
        let r = recognizer([".", "..", "..."])
        press(r, at: 0, for: 0.1)
        r.buttonDown(at: 0.3)
        #expect(scheduler.active == 0)
        r.buttonUp(at: 0.4)
        scheduler.elapse()
        #expect(emitted == [".."])
    }

    @Test func sequenceStopsAtMaxLength() {
        // Config never allows patterns this long, but the recognizer must still stop at the limit.
        let r = recognizer([String(repeating: ".", count: PressTiming.maxLength + 1)])
        for i in 0..<PressTiming.maxLength { press(r, at: Double(i) * 0.3, for: 0.1) }
        #expect(emitted == [String(repeating: ".", count: PressTiming.maxLength)])
    }

    @Test func separateSequencesAfterTheGap() {
        let r = recognizer([".", ".."])
        press(r, at: 0, for: 0.1)
        scheduler.elapse()
        press(r, at: 5, for: 0.1)
        press(r, at: 5.2, for: 0.1)
        #expect(emitted == [".", ".."])
    }
}
