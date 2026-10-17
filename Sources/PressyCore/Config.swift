import Foundation

public enum Action: Equatable, Sendable, CustomStringConvertible {
    case builtin(BuiltinAction)
    case shortcut(String)
    case run(String)

    public var description: String {
        switch self {
        case .builtin(let b): "builtin \(b.rawValue)"
        case .shortcut(let name): "shortcut \"\(name)\""
        case .run(let command): "run \"\(command)\""
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
    public var patterns: [String: Action] = [:]

    public init() {}

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
            for (pattern, actionValue) in patterns {
                try validate(pattern: pattern)
                config.patterns[pattern] = try action(actionValue, at: "patterns[\"\(pattern)\"]")
            }
        }
        return config
    }

    static func validate(pattern: String) throws {
        guard (1...PressTiming.maxLength).contains(pattern.count), pattern.allSatisfy({ $0 == "." || $0 == "-" }) else {
            throw ConfigError("patterns[\"\(pattern)\"]: a pattern is 1 to \(PressTiming.maxLength) of \".\" (short) and \"-\" (long)")
        }
    }

    private static func action(_ value: Any, at path: String) throws -> Action {
        guard let object = value as? [String: Any] else {
            throw ConfigError("\(path): must be an object with one of \"builtin\", \"shortcut\", \"run\"")
        }
        try rejectUnknownKeys(object, allowed: ["builtin", "shortcut", "run"], at: path)
        guard object.count == 1, let (kind, raw) = object.first else {
            throw ConfigError("\(path): needs exactly one of \"builtin\", \"shortcut\", \"run\"")
        }
        guard let text = raw as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConfigError("\(path).\(kind): must be a non-empty string")
        }
        switch kind {
        case "builtin":
            guard let builtin = BuiltinAction(rawValue: text) else {
                throw ConfigError("\(path).builtin: unknown \"\(text)\" (see: pressy actions)")
            }
            return .builtin(builtin)
        case "shortcut": return .shortcut(text)
        default: return .run(text)
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
