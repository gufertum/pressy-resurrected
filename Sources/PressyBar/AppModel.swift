import AppKit
import Foundation
import Observation
import PressyCore

/// One line in the activity list.
struct ActivityItem: Identifiable {
    enum Kind { case press, pattern, action, info }

    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String
    let ok: Bool
}

/// What the daemon last reported about itself.
struct DaemonState {
    var version: String
    var pid: Int
    var inputMonitoring: Bool
    var jack: Bool
    var config: String
}

@MainActor
@Observable
final class AppModel {
    static let daemonLabel = "li.sudo.pressy"
    static let pressyBinary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/pressy").path
    private static let activityLimit = 30

    let configURL = Config.defaultURL()
    private(set) var config = Config()
    private(set) var loadError: String?
    private(set) var daemon: DaemonState?
    /// False after a ping went unanswered.
    private(set) var daemonReachable = true
    private(set) var activity: [ActivityItem] = []
    private(set) var shortcuts: [String] = []
    /// True for a moment after a press, for the menu bar icon.
    private(set) var flashing = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var awaitingPong = false

    /// Demo mode shows fixed sample data and touches neither the config file nor the daemon (screenshots).
    @ObservationIgnored private let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            loadDemo()
            return
        }
        reload()
        observeDaemon()
        ping()
        Task { await refreshShortcuts() }
    }

    func reload() {
        guard !demo else { return }
        do {
            config = try Config.load(from: configURL)
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
    }

    /// Validates by parsing what will be written, writes atomically in the file's format, then restarts the daemon.
    func save(_ draft: Config) throws {
        guard !demo else { return }
        let format = ConfigFormat(url: configURL)
        let data = draft.encoded(as: format)
        _ = try Config.parse(data, format: format)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configURL, options: .atomic)
        config = draft
        loadError = nil
        record(.info, "configuration saved", ok: true)
        restartDaemon()
    }

    func restartDaemon() {
        guard !demo else { return }
        let (status, output) = Self.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(Self.daemonLabel)"])
        if status == 0 {
            record(.info, "daemon restarted", ok: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.ping() }
        } else {
            record(.info, "restart failed: \(output.isEmpty ? "is the LaunchAgent installed? (make install)" : output)", ok: false)
        }
    }

    /// Runs one pattern of an unsaved draft through `pressy trigger`, so the editor can test before saving.
    func test(pattern: String, in draft: Config) async -> (ok: Bool, output: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pressy-test-\(UUID().uuidString).json")
        do { try draft.jsonData().write(to: file) } catch { return (false, error.localizedDescription) }
        defer { try? FileManager.default.removeItem(at: file) }
        let binary = Self.pressyBinary
        let (status, output) = await Task.detached { Self.run(binary, ["trigger", pattern, "--config", file.path]) }.value
        return (status == 0, output)
    }

    func refreshShortcuts() async {
        let (status, output) = await Task.detached { Self.run("/usr/bin/shortcuts", ["list"]) }.value
        if status == 0 { shortcuts = output.split(separator: "\n").map(String.init).sorted() }
    }

    func ping() {
        guard !demo else { return }
        awaitingPong = true
        PressyEvent.post(PressyEvent.ping, [:])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.awaitingPong else { return }
            self.daemonReachable = false
        }
    }

    func openLog() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/pressy.log"))
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    private func observeDaemon() {
        let center = DistributedNotificationCenter.default()
        let names = [PressyEvent.press, PressyEvent.pattern, PressyEvent.action, PressyEvent.state]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                let event = Event(name: note.name, info: info)
                MainActor.assumeIsolated { self?.handle(event) }
            })
        }
    }

    /// The parts of a notification the model uses, copied out so nothing non-Sendable crosses actors.
    private struct Event: Sendable {
        let name: Notification.Name
        let ms: Int
        let pattern: String
        let actions: String
        let action: String
        let detail: String
        let mapped: Bool
        let ok: Bool
        let state: (version: String, pid: Int, inputMonitoring: Bool, jack: Bool, config: String)

        init(name: Notification.Name, info: [AnyHashable: Any]) {
            typealias K = PressyEvent.Key
            self.name = name
            ms = info[K.ms] as? Int ?? 0
            pattern = info[K.pattern] as? String ?? ""
            actions = info[K.actions] as? String ?? ""
            action = info[K.action] as? String ?? ""
            detail = info[K.detail] as? String ?? ""
            mapped = info[K.mapped] as? Bool ?? false
            ok = info[K.ok] as? Bool ?? false
            state = (info[K.version] as? String ?? "?", info[K.pid] as? Int ?? 0, info[K.inputMonitoring] as? Bool ?? false,
                     info[K.jack] as? Bool ?? false, info[K.config] as? String ?? "")
        }
    }

    private func handle(_ event: Event) {
        switch event.name {
        case PressyEvent.press:
            record(.press, "press \(event.ms) ms", ok: true)
            flashing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.flashing = false }
        case PressyEvent.pattern:
            record(.pattern, event.mapped ? "\(event.pattern)  →  \(event.actions)" : "\(event.pattern)  (not mapped)", ok: event.mapped)
        case PressyEvent.action:
            let detail = event.detail.isEmpty ? "" : " - \(event.detail)"
            record(.action, "\(event.action) \(event.ok ? "done" : "failed") in \(event.ms) ms\(detail)", ok: event.ok)
        case PressyEvent.state:
            awaitingPong = false
            daemonReachable = true
            let s = event.state
            daemon = DaemonState(version: s.version, pid: s.pid, inputMonitoring: s.inputMonitoring, jack: s.jack, config: s.config)
        default:
            break
        }
    }

    private func loadDemo() {
        var sample = Config()
        sample.patterns = [
            ".": [.builtin(.spotifyPlayPause)],
            "..": [.builtin(.spotifyNext)],
            "-": [.sound("Tink"), .builtin(.inputToggleMute)],
            ".-": [.raycast("raycast://confetti")],
            "-.": [.shortcut("Focus: Deep Work")],
            "--": [.builtin(.systemLock)],
            "...": [.keys(try! KeyCombo(parsing: "shift+cmd+4"))],
        ]
        config = sample
        daemon = DaemonState(version: "0.4.0", pid: 4711, inputMonitoring: true, jack: true, config: configURL.path)
        shortcuts = ["Focus: Deep Work", "Log water", "Start timer"]
        // Oldest first; the list shows the newest on top.
        record(.press, "press 174 ms", ok: true)
        record(.pattern, ".  →  builtin spotify.playpause", ok: true)
        record(.action, "builtin spotify.playpause done in 118 ms", ok: true)
        record(.press, "press 158 ms", ok: true)
        record(.press, "press 612 ms", ok: true)
        record(.pattern, ".-  →  raycast \"raycast://confetti\"", ok: true)
        record(.action, "raycast \"raycast://confetti\" done in 41 ms", ok: true)
    }

    private func record(_ kind: ActivityItem.Kind, _ text: String, ok: Bool) {
        activity.insert(ActivityItem(kind: kind, text: text, ok: ok), at: 0)
        if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
    }

    nonisolated static func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
