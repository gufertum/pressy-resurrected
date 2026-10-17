import Foundation

/// Timing rules for turning presses into patterns.
public struct PressTiming: Sendable, Equatable {
    /// Longest pattern, in presses. Longer sequences are emitted as soon as they reach this length.
    public static let maxLength = 5

    /// A press held at least this long counts as long ("-"), anything shorter as short (".").
    public var longPress: TimeInterval
    /// Silence after a release that ends the sequence.
    public var sequenceGap: TimeInterval

    public init(longPress: TimeInterval = 0.5, sequenceGap: TimeInterval = 0.4) {
        self.longPress = longPress
        self.sequenceGap = sequenceGap
    }
}

/// Turns button down/up edges into patterns: "." short press, "-" long press, e.g. ".." or ".-".
/// A pattern is emitted after `sequenceGap` without a new press, or right away when no known
/// pattern could still extend it, so a lone mapping like "-" fires on release without waiting.
@MainActor
public final class PatternRecognizer {
    /// Runs `work` after a delay on the main actor and returns a function that cancels it.
    public typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    private let timing: PressTiming
    private let knownPatterns: Set<String>
    private let schedule: Schedule
    private let emit: (String) -> Void

    private var pattern = ""
    private var downAt: TimeInterval?
    private var cancelPending: (() -> Void)?

    public init(timing: PressTiming, knownPatterns: Set<String>, schedule: @escaping Schedule, emit: @escaping (String) -> Void) {
        self.timing = timing
        self.knownPatterns = knownPatterns
        self.schedule = schedule
        self.emit = emit
    }

    /// Repeated edges in the same direction are ignored, so duplicate HID reports are harmless.
    public func buttonDown(at time: TimeInterval) {
        guard downAt == nil else { return }
        cancelPending?()
        cancelPending = nil
        downAt = time
    }

    public func buttonUp(at time: TimeInterval) {
        guard let start = downAt else { return }
        downAt = nil
        pattern += time - start >= timing.longPress ? "-" : "."

        let current = pattern
        let extendable = knownPatterns.contains { $0.count > current.count && $0.hasPrefix(current) }
        if !extendable || pattern.count >= PressTiming.maxLength {
            flush()
        } else {
            cancelPending = schedule(timing.sequenceGap) { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        cancelPending?()
        cancelPending = nil
        let finished = pattern
        pattern = ""
        if !finished.isEmpty { emit(finished) }
    }
}
