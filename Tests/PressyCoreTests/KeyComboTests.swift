@testable import PressyCore
import Testing

struct KeyComboTests {
    @Test(arguments: [
        ("cmd+shift+4", "shift+cmd+4", "⇧⌘4"),
        ("ctrl+cmd+q", "ctrl+cmd+q", "⌃⌘Q"),
        ("Command+Option+Escape", "opt+cmd+escape", "⌥⌘Escape"),
        ("⌘+space", "cmd+space", "⌘Space"),
        ("f5", "f5", "F5"),
        ("ctrl + up", "ctrl+up", "⌃Up"),
        ("cmd+plus", "cmd+plus", "⌘+"),
        ("alt+z", "opt+z", "⌥Z"),
    ])
    func parses(input: String, canonical: String, symbols: String) throws {
        let combo = try KeyCombo(parsing: input)
        #expect(combo.description == canonical)
        #expect(combo.symbols == symbols)
        #expect(try KeyCombo(parsing: combo.description) == combo)
    }

    @Test func namedKeysUseFixedCodes() throws {
        #expect(try KeyCombo(parsing: "return").key == .named("return", code: 36))
        #expect(try KeyCombo(parsing: "esc").key == .named("esc", code: 53))
        #expect(try KeyCombo(parsing: "q").key == .character("q"))
    }

    @Test(arguments: ["", "+", "cmd+", "cmd++x", "super+x", "cmd+xy"])
    func rejects(input: String) {
        #expect(throws: ConfigError.self) { try KeyCombo(parsing: input) }
    }
}
