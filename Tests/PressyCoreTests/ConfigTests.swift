import Foundation
@testable import PressyCore
import Testing

struct ConfigTests {
    func parse(_ json: String) throws -> Config { try Config.parse(Data(json.utf8)) }

    func error(_ json: String) -> String? {
        do {
            _ = try parse(json)
            return nil
        } catch let error as ConfigError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    @Test func exampleConfigInTheRepoIsValid() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../config.example.json")
        let config = try Config.load(from: url)
        #expect(!config.patterns.isEmpty)
    }

    @Test func fullConfig() throws {
        let config = try parse("""
            {"longPressMs": 600, "sequenceGapMs": 350, "restoreAudioRoute": false, "actionTimeoutSeconds": 10,
             "patterns": {".": {"builtin": "spotify.playpause"}, "..": {"shortcut": "Focus"}, "-.": {"run": "say hi"}}}
            """)
        #expect(config.timing == PressTiming(longPress: 0.6, sequenceGap: 0.35))
        #expect(config.restoreAudioRoute == false)
        #expect(config.actionTimeout == 10)
        #expect(config.patterns == [".": [.builtin(.spotifyPlayPause)], "..": [.shortcut("Focus")], "-.": [.run("say hi")]])
    }

    @Test func newActionKindsAndLists() throws {
        let config = try parse("""
            {"patterns": {
              ".": {"script": "~/bin/x.sh"},
              "..": {"keys": "Cmd+Shift+4"},
              "-": {"raycast": "confetti"},
              "--": {"raycast": "raycast://extensions/raycast/raycast/confetti"},
              ".-": [{"sound": "Glass"}, {"builtin": "input.togglemute"}]
            }}
            """)
        #expect(config.patterns["."] == [.script("~/bin/x.sh")])
        #expect(config.patterns[".."] == [.keys(KeyCombo(modifiers: [.cmd, .shift], key: .character("4")))])
        #expect(config.patterns["-"] == [.raycast("raycast://confetti")])
        #expect(config.patterns["--"] == [.raycast("raycast://extensions/raycast/raycast/confetti")])
        #expect(config.patterns[".-"] == [.sound("Glass"), .builtin(.inputToggleMute)])
    }

    @Test func jsonDataRoundTrips() throws {
        let original = try parse("""
            {"longPressMs": 650, "sequenceGapMs": 300, "restoreAudioRoute": false, "actionTimeoutSeconds": 12,
             "patterns": {".": {"keys": "ctrl+cmd+q"}, "..": [{"sound": "Glass"}, {"shortcut": "A/B"}], "-": {"raycast": "confetti"}}}
            """)
        let data = original.jsonData()
        #expect(try Config.parse(data) == original)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""keys" : "ctrl+cmd+q""#))
        #expect(text.contains(#""shortcut" : "A/B""#))
    }

    @Test func defaultsWhenKeysAreMissing() throws {
        let config = try parse("{}")
        #expect(config == Config())
        #expect(config.timing == PressTiming(longPress: 0.5, sequenceGap: 0.4))
        #expect(config.restoreAudioRoute)
    }

    @Test(arguments: [
        (#"{"longpressMs": 500}"#, #"config: unknown key "longpressMs""#),
        (#"{"patterns": {".": {"shorcut": "x"}}}"#, #"patterns["."]: unknown key "shorcut""#),
        (#"{"patterns": {".": {"run": "a", "shortcut": "b"}}}"#, #"patterns["."]: needs exactly one of"#),
        (#"{"patterns": {".": {}}}"#, #"patterns["."]: needs exactly one of"#),
        (#"{"patterns": {".": {"run": "  "}}}"#, #"patterns["."].run: must be a non-empty string"#),
        (#"{"patterns": {".": {"builtin": "spotify.play"}}}"#, #"patterns["."].builtin: unknown "spotify.play""#),
        (#"{"patterns": {".x": {"run": "a"}}}"#, #"patterns[".x"]: a pattern is 1 to 5"#),
        (#"{"patterns": {"......": {"run": "a"}}}"#, #"patterns["......"]: a pattern is 1 to 5"#),
        (#"{"patterns": {"": {"run": "a"}}}"#, #"patterns[""]: a pattern is 1 to 5"#),
        (#"{"patterns": {".": "say hi"}}"#, #"patterns["."]: must be an object"#),
        (#"{"patterns": []}"#, "patterns: must be an object"),
        (#"{"longPressMs": "500"}"#, "longPressMs: must be a number from 100 to 5000"),
        (#"{"longPressMs": true}"#, "longPressMs: must be a number from 100 to 5000"),
        (#"{"sequenceGapMs": 50}"#, "sequenceGapMs: must be a number from 100 to 3000"),
        (#"{"restoreAudioRoute": 1}"#, "restoreAudioRoute: must be true or false"),
        ("[]", "top level must be a JSON object"),
        ("{", "invalid JSON"),
        (#"{"patterns": {".": []}}"#, #"patterns["."]: the action list is empty"#),
        (#"{"patterns": {".": [{"sound": "Glass"}, {"nope": "x"}]}}"#, #"patterns["."][1]: unknown key "nope""#),
        (#"{"patterns": {".": {"keys": "hyper+x"}}}"#, #"patterns["."].keys "hyper+x": unknown modifier "hyper""#),
        (#"{"patterns": {".": {"keys": "cmd+"}}}"#, #"patterns["."].keys "cmd+": write it like"#),
        (#"{"patterns": {".": {"keys": "cmd+banana"}}}"#, #"patterns["."].keys "cmd+banana": unknown key "banana""#),
        (#"{"patterns": {".": {"sound": 3}}}"#, #"patterns["."].sound: must be a non-empty string"#),
    ])
    func rejects(json: String, message: String) {
        let actual = error(json)
        #expect(actual?.hasPrefix(message) == true, "got: \(actual ?? "no error")")
    }

    @Test func loadPrefixesThePath() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pressy-test-\(UUID()).json")
        try? Data(#"{"nope": 1}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ConfigError("\(url.path): config: unknown key \"nope\" (allowed: actionTimeoutSeconds, longPressMs, patterns, restoreAudioRoute, sequenceGapMs)")) {
            try Config.load(from: url)
        }
    }

    @Test func defaultURLHonoursEnvironment() {
        #expect(Config.defaultURL(environment: ["PRESSY_CONFIG": "/tmp/p.json"]).path == "/tmp/p.json")
        #expect(Config.defaultURL(environment: ["XDG_CONFIG_HOME": "/x"]).path == "/x/pressy/config.json")
        #expect(Config.defaultURL(environment: [:]).path.hasSuffix("/.config/pressy/config.json"))
    }
}
