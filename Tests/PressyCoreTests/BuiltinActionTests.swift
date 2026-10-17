import PressyCore
import Testing

struct BuiltinActionTests {
    @Test(arguments: BuiltinAction.allCases)
    func isWellFormed(builtin: BuiltinAction) throws {
        #expect(builtin.rawValue.allSatisfy { $0.isLowercase || $0 == "." })
        #expect(!builtin.category.isEmpty)
        #expect(!builtin.summary.isEmpty)
        if case .keys(let text) = builtin.implementation {
            _ = try KeyCombo(parsing: text)
            #expect(builtin.needsAccessibility)
        }
    }

    @Test func accessibilityOnlyForKeysAndMediaKeys() {
        #expect(BuiltinAction.mediaPlayPause.needsAccessibility)
        #expect(BuiltinAction.systemLock.needsAccessibility)
        #expect(!BuiltinAction.spotifyPlayPause.needsAccessibility)
        #expect(!BuiltinAction.appearanceToggle.needsAccessibility)
    }

    @Test func configAcceptsEveryBuiltin() throws {
        for builtin in BuiltinAction.allCases {
            #expect(try Action.make(kind: "builtin", value: builtin.rawValue) == .builtin(builtin))
        }
    }
}
