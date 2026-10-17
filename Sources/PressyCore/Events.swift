import Foundation

/// Contract between the daemon and the menu bar app: distributed notifications in the user session.
/// All userInfo values are strings, numbers or booleans. Fire-and-forget; nothing is queued while the
/// app is not running, so the app asks for the current state with `ping` when it starts.
public enum PressyEvent {
    /// daemon -> app, on every release: `ms`
    public static let press = Notification.Name("li.sudo.pressy.press")
    /// daemon -> app, recognised pattern: `pattern`, `actions` (descriptions joined), `mapped`
    public static let pattern = Notification.Name("li.sudo.pressy.pattern")
    /// daemon -> app, one finished action: `pattern`, `action`, `ok`, `ms`, `detail`
    public static let action = Notification.Name("li.sudo.pressy.action")
    /// daemon -> app, at start, on `ping` and when the jack changes: `version`, `pid`, `inputMonitoring`, `jack`, `config`
    public static let state = Notification.Name("li.sudo.pressy.state")
    /// app -> daemon: answer with `state`
    public static let ping = Notification.Name("li.sudo.pressy.ping")

    public enum Key {
        public static let ms = "ms"
        public static let pattern = "pattern"
        public static let actions = "actions"
        public static let mapped = "mapped"
        public static let action = "action"
        public static let ok = "ok"
        public static let detail = "detail"
        public static let version = "version"
        public static let pid = "pid"
        public static let inputMonitoring = "inputMonitoring"
        public static let jack = "jack"
        public static let config = "config"
    }

    public static func post(_ name: Notification.Name, _ info: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
    }
}

extension AudioDeviceSnapshot {
    /// True for the devices macOS creates when a headset (or a Pressy) is in the jack.
    public var isJack: Bool { outputSource == "hdpn" || inputSource == "emic" }
}
