import Foundation

/// A key combination like "cmd+shift+4" or "ctrl+up", parsed from the config.
public struct KeyCombo: Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Modifier: String, CaseIterable, Sendable, Comparable {
        case ctrl, opt, shift, cmd, fn

        static let aliases: [String: Modifier] = [
            "ctrl": .ctrl, "control": .ctrl, "⌃": .ctrl,
            "opt": .opt, "option": .opt, "alt": .opt, "⌥": .opt,
            "shift": .shift, "⇧": .shift,
            "cmd": .cmd, "command": .cmd, "⌘": .cmd,
            "fn": .fn,
        ]

        public var symbol: String {
            switch self {
            case .ctrl: "⌃"
            case .opt: "⌥"
            case .shift: "⇧"
            case .cmd: "⌘"
            case .fn: "fn"
            }
        }

        public static func < (a: Modifier, b: Modifier) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public enum Key: Equatable, Hashable, Sendable {
        /// A character, resolved to a key code through the current keyboard layout at press time.
        case character(Character)
        /// A key without a character, by fixed virtual key code.
        case named(String, code: UInt16)
    }

    /// Virtual key codes of keys that have no character (positions are layout independent).
    public static let namedKeys: [String: UInt16] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "help": 114,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]

    public let modifiers: Set<Modifier>
    public let key: Key

    public init(modifiers: Set<Modifier>, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Parses "cmd+shift+4", "ctrl+cmd+q", "f5", "opt+space". A plus sign itself is written "plus".
    public init(parsing text: String) throws {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty, !parts.dropLast().contains(where: \.isEmpty) else {
            throw ConfigError("keys \"\(text)\": write it like \"cmd+shift+4\"")
        }
        var modifiers = Set<Modifier>()
        for part in parts.dropLast() {
            guard let modifier = Modifier.aliases[part] else {
                throw ConfigError("keys \"\(text)\": unknown modifier \"\(part)\" (cmd, shift, ctrl, opt, fn)")
            }
            modifiers.insert(modifier)
        }
        if let code = Self.namedKeys[last] {
            key = .named(last, code: code)
        } else if last == "plus" {
            key = .character("+")
        } else if last.count == 1, let character = last.first {
            key = .character(character)
        } else {
            throw ConfigError("keys \"\(text)\": unknown key \"\(last)\" (a single character, or one of: \(Self.namedKeys.keys.sorted().joined(separator: ", ")))")
        }
        self.modifiers = modifiers
    }

    /// Canonical config form, e.g. "ctrl+cmd+q".
    public var description: String {
        let keyName: String
        switch key {
        case .character("+"): keyName = "plus"
        case .character(let c): keyName = String(c)
        case .named(let name, _): keyName = name
        }
        return (modifiers.sorted().map(\.rawValue) + [keyName]).joined(separator: "+")
    }

    /// Display form, e.g. "⌃⌘Q".
    public var symbols: String {
        let keyName: String
        switch key {
        case .character(let c): keyName = String(c).uppercased()
        case .named(let name, _): keyName = name.capitalized
        }
        return modifiers.sorted().map(\.symbol).joined() + keyName
    }
}
