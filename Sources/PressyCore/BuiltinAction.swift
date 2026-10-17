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

    public var summary: String {
        switch self {
        case .mediaPlayPause: "System play/pause key: whatever is playing (needs Accessibility)"
        case .mediaNext: "System next-track key (needs Accessibility)"
        case .mediaPrevious: "System previous-track key (needs Accessibility)"
        case .spotifyPlayPause: "Spotify play/pause, if Spotify is running (asks once to control Spotify)"
        case .spotifyNext: "Spotify next track"
        case .spotifyPrevious: "Spotify previous track"
        case .musicPlayPause: "Apple Music play/pause, if Music is running (asks once to control Music)"
        case .musicNext: "Apple Music next track"
        case .musicPrevious: "Apple Music previous track"
        case .outputToggleMute: "Mute/unmute the current output device"
        case .outputVolumeUp: "Output volume up one step (1/16), unmutes"
        case .outputVolumeDown: "Output volume down one step (1/16)"
        case .inputToggleMute: "Mute/unmute the current input device (microphone)"
        }
    }

    /// Posting system media keys is gated by the Accessibility permission.
    public var needsAccessibility: Bool {
        switch self {
        case .mediaPlayPause, .mediaNext, .mediaPrevious: true
        default: false
        }
    }
}
