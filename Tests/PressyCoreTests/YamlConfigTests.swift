import Foundation
@testable import PressyCore
import Testing

struct YamlConfigTests {
    func parse(_ yaml: String) throws -> Config { try Config.parse(Data(yaml.utf8), format: .yaml) }

    @Test func parsesTheSameAsJson() throws {
        let yaml = try parse("""
            longPressMs: 600
            restoreAudioRoute: false
            patterns:
              ".": { builtin: spotify.playpause }
              "-":
                - sound: Tink
                - keys: cmd+shift+4
              ".-": { raycast: confetti }
            """)
        let json = try Config.parse(Data("""
            {"longPressMs": 600, "restoreAudioRoute": false, "patterns": {
              ".": {"builtin": "spotify.playpause"}, "-": [{"sound": "Tink"}, {"keys": "cmd+shift+4"}], ".-": {"raycast": "confetti"}}}
            """.utf8))
        #expect(yaml == json)
    }

    @Test func strictValidationAppliesToYamlToo() {
        #expect(throws: ConfigError("config: unknown key \"longpressMs\" (allowed: actionTimeoutSeconds, longPressMs, patterns, restoreAudioRoute, sequenceGapMs)")) {
            try parse("longpressMs: 500")
        }
        #expect(throws: ConfigError("restoreAudioRoute: must be true or false")) { try parse("restoreAudioRoute: 1") }
        #expect(throws: ConfigError("longPressMs: must be a number from 100 to 5000")) { try parse("longPressMs: \"500\"") }
        #expect(throws: ConfigError("patterns[\".\"].builtin: unknown \"nope\" (see: pressy actions)")) {
            try parse("patterns:\n  \".\": { builtin: nope }")
        }
    }

    @Test func anUnquotedDashGivesAHint() {
        do {
            _ = try parse("patterns:\n  - { builtin: spotify.next }")
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains("quote the patterns"))
        }
    }

    @Test func emptyFileIsAnEmptyConfig() throws {
        #expect(try parse("") == Config())
        #expect(try parse("# only a comment\n") == Config())
    }

    @Test func invalidYamlIsReported() {
        #expect(throws: ConfigError.self) { try parse("patterns: [unclosed") }
    }

    @Test func yamlDataRoundTripsTrickyValues() throws {
        var config = Config()
        config.timing = PressTiming(longPress: 0.65, sequenceGap: 0.3)
        config.restoreAudioRoute = false
        config.patterns = [
            ".": [.run("echo \"a: b\" # not a comment 'x' \\ / ünïcødé 🎉")],
            "-": [.sound("Tink"), .builtin(.inputToggleMute)],
            "..": [.shortcut("Focus: on/off")],
            "-.": [.keys(try KeyCombo(parsing: "cmd+plus"))],
        ]
        let data = config.yamlData()
        #expect(try Config.parse(data, format: .yaml) == config)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#"  "-":"#))
        #expect(text.contains(#"    - sound: "Tink""#))
        #expect(text.contains(#"  "..": { shortcut: "Focus: on/off" }"#))
        // Display order: short before long, fewer presses first.
        let order = ["\".\":", "\"-\":", "\"..\":", "\"-.\":"].map { text.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
    }

    @Test func emptyPatternsRoundTrip() throws {
        #expect(try Config.parse(Config().yamlData(), format: .yaml) == Config())
    }
}
