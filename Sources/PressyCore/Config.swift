import Foundation

public enum Action: Equatable, Hashable, Sendable, CustomStringConvertible {
    case builtin(BuiltinAction)
    case shortcut(String)
    case run(String)
    case script(String)
    case keys(KeyCombo)
    case raycast(String)
    case sound(String)

    /// Config keys, in the order the editor offers them.
    public static let kinds = ["builtin", "shortcut", "script", "run", "keys", "raycast", "sound"]

    /// Builds an action from its config key and value; the single place both the parser and the editor use.
    public static func make(kind: String, value: String) throws -> Action {
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { throw ConfigError("\(kind): must be a non-empty string") }
        switch kind {
        case "builtin":
            guard let builtin = BuiltinAction(rawValue: value) else { throw ConfigError("builtin: unknown \"\(value)\" (see: pressy actions)") }
            return .builtin(builtin)
        case "shortcut": return .shortcut(value)
        case "run": return .run(value)
        case "script": return .script(value)
        case "keys": return .keys(try KeyCombo(parsing: value))
        case "raycast":
            let url = value.hasPrefix("raycast://") ? value : "raycast://" + value.drop(while: { $0 == "/" })
            guard URL(string: url) != nil else { throw ConfigError("raycast: \"\(value)\" is not a valid deeplink") }
            return .raycast(url)
        case "sound": return .sound(value)
        default: throw ConfigError("unknown action \"\(kind)\" (allowed: \(kinds.joined(separator: ", ")))")
        }
    }

    public var kind: String {
        switch self {
        case .builtin: "builtin"
        case .shortcut: "shortcut"
        case .run: "run"
        case .script: "script"
        case .keys: "keys"
        case .raycast: "raycast"
        case .sound: "sound"
        }
    }

    /// The value as written in the config.
    public var value: String {
        switch self {
        case .builtin(let b): b.rawValue
        case .shortcut(let s), .run(let s), .script(let s), .raycast(let s), .sound(let s): s
        case .keys(let combo): combo.description
        }
    }

    public var description: String {
        switch self {
        case .builtin(let b): "builtin \(b.rawValue)"
        case .keys(let combo): "keys \(combo)"
        default: "\(kind) \"\(value)\""
        }
    }
}

public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The JSON config, by default `~/.config/pressy/config.json`. Unknown keys are errors, so typos fail loudly.
public struct Config: Equatable, Sendable {
    public var timing = PressTiming()
    /// Undo the switch to the jack's "headphones" and "microphone" that macOS performs on plug-in.
    public var restoreAudioRoute = true
    public var actionTimeout: TimeInterval = 30
    /// Pattern -> actions, run one after another. In JSON a single action may be written without the list.
    public var patterns: [String: [Action]] = [:]

    public init() {}

    public var allActions: [Action] { patterns.values.flatMap { $0 } }

    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["PRESSY_CONFIG"], !path.isEmpty { return URL(fileURLWithPath: path) }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("pressy/config.json")
    }

    public static func load(from url: URL) throws -> Config {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ConfigError("\(url.path): cannot read: \(error.localizedDescription)")
        }
        do { return try parse(data) } catch let error as ConfigError {
            throw ConfigError("\(url.path): \(error.message)")
        }
    }

    public static func parse(_ data: Data) throws -> Config {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch {
            throw ConfigError("invalid JSON: \(error.localizedDescription)")
        }
        guard let object = root as? [String: Any] else { throw ConfigError("top level must be a JSON object") }
        try rejectUnknownKeys(object, allowed: ["longPressMs", "sequenceGapMs", "restoreAudioRoute", "actionTimeoutSeconds", "patterns"], at: "config")

        var config = Config()
        if let v = object["longPressMs"] { config.timing.longPress = try number(v, "longPressMs", 100...5000) / 1000 }
        if let v = object["sequenceGapMs"] { config.timing.sequenceGap = try number(v, "sequenceGapMs", 100...3000) / 1000 }
        if let v = object["actionTimeoutSeconds"] { config.actionTimeout = try number(v, "actionTimeoutSeconds", 1...3600) }
        if let v = object["restoreAudioRoute"] {
            guard let b = v as? NSNumber, isBool(b) else { throw ConfigError("restoreAudioRoute: must be true or false") }
            config.restoreAudioRoute = b.boolValue
        }
        if let v = object["patterns"] {
            guard let patterns = v as? [String: Any] else { throw ConfigError("patterns: must be an object of pattern -> action") }
            for (pattern, value) in patterns {
                try validate(pattern: pattern)
                let path = "patterns[\"\(pattern)\"]"
                if let list = value as? [Any] {
                    guard !list.isEmpty else { throw ConfigError("\(path): the action list is empty") }
                    config.patterns[pattern] = try list.enumerated().map { try action($1, at: "\(path)[\($0)]") }
                } else {
                    config.patterns[pattern] = [try action(value, at: path)]
                }
            }
        }
        return config
    }

    /// Pretty, key-sorted JSON that `parse` reads back to an equal config. Single actions are written without a list.
    public func jsonData() -> Data {
        var patternObjects: [String: Any] = [:]
        for (pattern, actions) in patterns {
            let objects = actions.map { [$0.kind: $0.value] }
            patternObjects[pattern] = objects.count == 1 ? objects[0] : objects
        }
        let object: [String: Any] = [
            "longPressMs": Int((timing.longPress * 1000).rounded()),
            "sequenceGapMs": Int((timing.sequenceGap * 1000).rounded()),
            "restoreAudioRoute": restoreAudioRoute,
            "actionTimeoutSeconds": Int(actionTimeout.rounded()),
            "patterns": patternObjects,
        ]
        // Only plist types above, so serialization cannot fail.
        return try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func validate(pattern: String) throws {
        guard (1...PressTiming.maxLength).contains(pattern.count), pattern.allSatisfy({ $0 == "." || $0 == "-" }) else {
            throw ConfigError("patterns[\"\(pattern)\"]: a pattern is 1 to \(PressTiming.maxLength) of \".\" (short) and \"-\" (long)")
        }
    }

    private static func action(_ value: Any, at path: String) throws -> Action {
        let kinds = Action.kinds.map { "\"\($0)\"" }.joined(separator: ", ")
        guard let object = value as? [String: Any] else {
            throw ConfigError("\(path): must be an object with one of \(kinds), or a list of them")
        }
        try rejectUnknownKeys(object, allowed: Set(Action.kinds), at: path)
        guard object.count == 1, let (kind, raw) = object.first else {
            throw ConfigError("\(path): needs exactly one of \(kinds)")
        }
        guard let text = raw as? String else { throw ConfigError("\(path).\(kind): must be a non-empty string") }
        do { return try Action.make(kind: kind, value: text) } catch let error as ConfigError {
            throw ConfigError("\(path).\(error.message)")
        }
    }

    private static func rejectUnknownKeys(_ object: [String: Any], allowed: Set<String>, at path: String) throws {
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ConfigError("\(path): unknown key \"\(unknown)\" (allowed: \(allowed.sorted().joined(separator: ", ")))")
        }
    }

    private static func number(_ value: Any, _ key: String, _ range: ClosedRange<Double>) throws -> Double {
        guard let n = value as? NSNumber, !isBool(n), range.contains(n.doubleValue) else {
            throw ConfigError("\(key): must be a number from \(Int(range.lowerBound)) to \(Int(range.upperBound))")
        }
        return n.doubleValue
    }

    /// JSONSerialization returns booleans as NSNumber too; only CFBoolean is a real JSON true/false.
    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
}

extension Action {
    /// Posting keys and system media keys is gated by the Accessibility permission.
    public var needsAccessibility: Bool {
        switch self {
        case .keys: true
        case .builtin(let b): b.needsAccessibility
        default: false
        }
    }
}
