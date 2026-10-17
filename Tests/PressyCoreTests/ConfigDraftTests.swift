import Foundation
import PressyCore
import Testing

struct ConfigDraftTests {
    let sample: Config = {
        var c = Config()
        c.timing = PressTiming(longPress: 0.6, sequenceGap: 0.3)
        c.restoreAudioRoute = false
        c.actionTimeout = 10
        c.patterns = [".": [.builtin(.spotifyPlayPause)], "..": [.sound("Glass"), .keys(try! KeyCombo(parsing: "ctrl+cmd+q"))], "-": [.raycast("raycast://confetti")]]
        return c
    }()

    @Test func roundTrips() throws {
        let draft = ConfigDraft(sample)
        #expect(draft.patterns.map(\.pattern) == [".", "-", ".."])
        #expect(try draft.build() == sample)
    }

    @Test func rejectsDuplicatesEmptyListsAndBadActions() {
        var draft = ConfigDraft(sample)
        draft.patterns[1].pattern = "."
        #expect(throws: ConfigError("pattern \".\" is used twice")) { try draft.build() }

        draft = ConfigDraft(sample)
        draft.patterns[0].actions = []
        #expect(throws: ConfigError("pattern \".\" has no action")) { try draft.build() }

        draft = ConfigDraft(sample)
        draft.patterns[0].actions[0].value = "nope"
        #expect(throws: ConfigError("pattern \".\": builtin: unknown \"nope\" (see: pressy actions)")) { try draft.build() }

        draft = ConfigDraft(sample)
        draft.longPressMs = 20
        #expect(throws: ConfigError("longPressMs: must be a number from 100 to 5000")) { try draft.build() }
    }

    @Test func problemDescribesAnInvalidAction() {
        #expect(ActionDraft(kind: "keys", value: "cmd+").problem?.hasPrefix("keys \"cmd+\"") == true)
        #expect(ActionDraft(kind: "keys", value: "cmd+k").problem == nil)
        for kind in Action.kinds where !["shortcut", "script", "run"].contains(kind) {
            #expect(ActionDraft(kind: kind, value: ActionDraft.defaultValue(for: kind)).problem == nil)
        }
    }

    @Test func nextFreePatternIsTheShortestUnused() {
        var draft = ConfigDraft(Config())
        #expect(draft.nextFreePattern == ".")
        draft.patterns = [PatternDraft(pattern: ".", actions: []), PatternDraft(pattern: "-", actions: [])]
        #expect(draft.nextFreePattern == "..")
    }
}
