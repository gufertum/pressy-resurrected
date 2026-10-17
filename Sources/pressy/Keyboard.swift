import AppKit
import Carbon
import CoreGraphics
import PressyCore

struct ActionError: Error, CustomStringConvertible {
    let description: String
}

/// Posts key combinations and system media keys. Both need the Accessibility permission.
@MainActor
enum Keyboard {
    static func post(_ combo: KeyCombo) throws(ActionError) {
        try requireAccess()
        let code: UInt16
        var flags = CGEventFlags()
        switch combo.key {
        case .named(_, let named):
            code = named
        case .character(let character):
            guard let resolved = keyCode(for: character) else {
                throw ActionError(description: "the current keyboard layout has no key for \"\(character)\"")
            }
            code = resolved.code
            if resolved.shift { flags.insert(.maskShift) }
        }
        for modifier in combo.modifiers {
            switch modifier {
            case .cmd: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .ctrl: flags.insert(.maskControl)
            case .opt: flags.insert(.maskAlternate)
            case .fn: flags.insert(.maskSecondaryFn)
            }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                throw ActionError(description: "creating the key event failed")
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// Posts a system media key (NX_KEYTYPE_*), which macOS routes to the app that is playing.
    static func postMediaKey(_ key: Int) throws(ActionError) {
        try requireAccess()
        for state in [0xA, 0xB] { // key down, key up
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                                           data1: (key << 16) | (state << 8), data2: -1)
            guard let cgEvent = event?.cgEvent else { throw ActionError(description: "creating the media key event failed") }
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    private static func requireAccess() throws(ActionError) {
        guard CGPreflightPostEventAccess() else {
            CGRequestPostEventAccess()
            throw ActionError(description: "no Accessibility permission to post keys; allow pressy in System Settings > Privacy & Security > Accessibility")
        }
    }

    private static let keypadCodes: Set<UInt16> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    /// Finds the key that types `character` on the current layout, so "z" is Z on QWERTZ too.
    /// Order: main keys unshifted, main keys shifted, then the numeric keypad.
    static func keyCode(for character: Character) -> (code: UInt16, shift: Bool)? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let wanted = String(character).lowercased()
        return data.withUnsafeBytes { raw -> (UInt16, Bool)? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            let main = (UInt16(0)..<128).filter { !keypadCodes.contains($0) }
            let passes = [(main, false), (main, true), (Array(keypadCodes).sorted(), false)]
            for (codes, shift) in passes {
                let modifierState = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                for code in codes {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifierState, UInt32(LMGetKbdType()),
                                                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
                    if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == wanted {
                        return (code, shift)
                    }
                }
            }
            return nil
        }
    }
}
