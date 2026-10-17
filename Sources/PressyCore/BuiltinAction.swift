/// How a built-in action runs. Adding a built-in is one case in `BuiltinAction` plus one line in `definition`.
public enum BuiltinImplementation: Equatable, Sendable {
    /// A child process, with the usual timeout.
    case process(String, [String])
    /// AppleScript run by `osascript`.
    case appleScript(String)
    /// A key combination, like the `keys` action.
    case keys(String)
    /// A system media key (NX_KEYTYPE_*).
    case mediaKey(Int)
    /// Implemented inside pressy (CoreAudio, state it keeps).
    case inProcess
}

/// Actions pressy performs itself, selected in the config with `{"builtin": "<name>"}`.
public enum BuiltinAction: String, CaseIterable, Sendable {
    case mediaPlayPause = "media.playpause"
    case mediaNext = "media.next"
    case mediaPrevious = "media.previous"
    case spotifyPlayPause = "spotify.playpause"
    case spotifyNext = "spotify.next"
    case spotifyPrevious = "spotify.previous"
    case musicPlayPause = "music.playpause"
    case musicNext = "music.next"
    case musicPrevious = "music.previous"
    case outputToggleMute = "output.togglemute"
    case outputVolumeUp = "output.volumeup"
    case outputVolumeDown = "output.volumedown"
    case inputToggleMute = "input.togglemute"
    case appearanceToggle = "appearance.toggle"
    case appearanceDark = "appearance.dark"
    case appearanceLight = "appearance.light"
    case displaySleep = "display.sleep"
    case systemSleep = "system.sleep"
    case systemLock = "system.lock"
    case screensaverStart = "screensaver.start"
    case screenshotTool = "screenshot.tool"
    case missionControl = "missioncontrol"
    case caffeinateToggle = "caffeinate.toggle"
    case timeSay = "time.say"

    public var category: String { definition.category }
    public var summary: String { definition.summary }
    public var implementation: BuiltinImplementation { definition.implementation }

    /// Posting keys and system media keys is gated by the Accessibility permission.
    public var needsAccessibility: Bool {
        switch implementation {
        case .keys, .mediaKey: true
        default: false
        }
    }

    private var definition: (category: String, summary: String, implementation: BuiltinImplementation) {
        switch self {
        case .mediaPlayPause: ("Media", "System play/pause key: whatever is playing (needs Accessibility)", .mediaKey(16))
        case .mediaNext: ("Media", "System next-track key (needs Accessibility)", .mediaKey(17))
        case .mediaPrevious: ("Media", "System previous-track key (needs Accessibility)", .mediaKey(18))
        case .spotifyPlayPause: ("Spotify", "Spotify play/pause, if Spotify is running", Self.ifRunning("Spotify", "playpause"))
        case .spotifyNext: ("Spotify", "Spotify next track", Self.ifRunning("Spotify", "next track"))
        case .spotifyPrevious: ("Spotify", "Spotify previous track", Self.ifRunning("Spotify", "previous track"))
        case .musicPlayPause: ("Music", "Apple Music play/pause, if Music is running", Self.ifRunning("Music", "playpause"))
        case .musicNext: ("Music", "Apple Music next track", Self.ifRunning("Music", "next track"))
        case .musicPrevious: ("Music", "Apple Music previous track", Self.ifRunning("Music", "previous track"))
        case .outputToggleMute: ("Audio", "Mute/unmute the current output device", .inProcess)
        case .outputVolumeUp: ("Audio", "Output volume up one step (1/16), unmutes", .inProcess)
        case .outputVolumeDown: ("Audio", "Output volume down one step (1/16)", .inProcess)
        case .inputToggleMute: ("Audio", "Mute/unmute the current microphone", .inProcess)
        case .appearanceToggle: ("Appearance", "Switch between dark and light mode", Self.darkMode("not dark mode"))
        case .appearanceDark: ("Appearance", "Dark mode", Self.darkMode("true"))
        case .appearanceLight: ("Appearance", "Light mode", Self.darkMode("false"))
        case .displaySleep: ("System", "Turn the displays off (locks when a password is required after sleep)", .process("/usr/bin/pmset", ["displaysleepnow"]))
        case .systemSleep: ("System", "Put the Mac to sleep", .process("/usr/bin/pmset", ["sleepnow"]))
        case .systemLock: ("System", "Lock the screen (⌃⌘Q, needs Accessibility)", .keys("ctrl+cmd+q"))
        case .screensaverStart: ("System", "Start the screen saver", .process("/usr/bin/open", ["-a", "ScreenSaverEngine"]))
        case .screenshotTool: ("System", "Open the screenshot tool (⇧⌘5, needs Accessibility)", .keys("shift+cmd+5"))
        case .missionControl: ("System", "Show Mission Control", .process("/usr/bin/open", ["-a", "Mission Control"]))
        case .caffeinateToggle: ("System", "Keep the Mac awake until pressed again", .inProcess)
        case .timeSay: ("System", "Speak the current time", .process("/bin/zsh", ["-c", "say \"$(date +%H:%M)\""]))
        }
    }

    /// Checking first keeps a press from launching the app.
    private static func ifRunning(_ app: String, _ command: String) -> BuiltinImplementation {
        .appleScript("if application \"\(app)\" is running then\ntell application \"\(app)\" to \(command)\nelse\nreturn \"\(app) is not running\"\nend if")
    }

    private static func darkMode(_ value: String) -> BuiltinImplementation {
        .appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)")
    }
}
