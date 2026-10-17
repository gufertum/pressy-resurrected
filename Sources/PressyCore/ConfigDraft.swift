import Foundation

/// An editable action: kind and value as text, so the editor can hold invalid states while typing.
public struct ActionDraft: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var kind: String
    public var value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }

    public init(_ action: Action) { self.init(kind: action.kind, value: action.value) }

    public func build() throws -> Action { try Action.make(kind: kind, value: value) }

    /// Why this action would be rejected, or nil.
    public var problem: String? {
        do {
            _ = try build()
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// A sensible value when the user switches to `kind`.
    public static func defaultValue(for kind: String) -> String {
        switch kind {
        case "builtin": BuiltinAction.spotifyPlayPause.rawValue
        case "keys": "cmd+space"
        case "raycast": "confetti"
        case "sound": "Glass"
        default: ""
        }
    }
}

public struct PatternDraft: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var pattern: String
    public var actions: [ActionDraft]

    public init(pattern: String, actions: [ActionDraft]) {
        self.pattern = pattern
        self.actions = actions
    }
}

/// The editor's working copy of a `Config`; `build()` turns it back into a validated config.
public struct ConfigDraft: Equatable, Sendable {
    public var longPressMs: Int
    public var sequenceGapMs: Int
    public var restoreAudioRoute: Bool
    public var actionTimeoutSeconds: Int
    public var patterns: [PatternDraft]

    public init(_ config: Config) {
        longPressMs = Int((config.timing.longPress * 1000).rounded())
        sequenceGapMs = Int((config.timing.sequenceGap * 1000).rounded())
        restoreAudioRoute = config.restoreAudioRoute
        actionTimeoutSeconds = Int(config.actionTimeout.rounded())
        patterns = config.sortedPatterns.map { pattern in
            PatternDraft(pattern: pattern, actions: config.patterns[pattern]!.map(ActionDraft.init))
        }
    }

    /// The shortest pattern not used yet, for "add pattern".
    public var nextFreePattern: String {
        let used = Set(patterns.map(\.pattern))
        for length in 1...PressTiming.maxLength {
            for candidate in Self.patterns(ofLength: length) where !used.contains(candidate) { return candidate }
        }
        return "."
    }

    public func build() throws -> Config {
        var config = Config()
        config.timing = PressTiming(longPress: Double(longPressMs) / 1000, sequenceGap: Double(sequenceGapMs) / 1000)
        config.restoreAudioRoute = restoreAudioRoute
        config.actionTimeout = Double(actionTimeoutSeconds)
        for draft in patterns {
            try Config.validate(pattern: draft.pattern)
            guard config.patterns[draft.pattern] == nil else { throw ConfigError("pattern \"\(draft.pattern)\" is used twice") }
            guard !draft.actions.isEmpty else { throw ConfigError("pattern \"\(draft.pattern)\" has no action") }
            do { config.patterns[draft.pattern] = try draft.actions.map { try $0.build() } } catch let error as ConfigError {
                throw ConfigError("pattern \"\(draft.pattern)\": \(error.message)")
            }
        }
        // The parser also enforces the ranges of the numbers.
        return try Config.parse(config.jsonData(), format: .json)
    }

    static func patterns(ofLength length: Int) -> [String] {
        guard length > 0 else { return [""] }
        return patterns(ofLength: length - 1).flatMap { [$0 + ".", $0 + "-"] }
    }
}
