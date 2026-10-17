import AppKit
import Foundation
import PressyCore

/// Executes actions. Child processes run asynchronously with a timeout; every outcome is logged.
@MainActor
final class ActionRunner {
    private let timeout: TimeInterval

    init(timeout: TimeInterval) { self.timeout = timeout }

    /// `completion` gets `true` when the action succeeded.
    func perform(_ action: Action, pattern: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        switch action {
        case .run(let command):
            spawn("/bin/zsh", ["-lc", command], label: action.description, pattern: pattern, completion: completion)
        case .shortcut(let name):
            spawn("/usr/bin/shortcuts", ["run", name], label: action.description, pattern: pattern, completion: completion)
        case .builtin(let builtin):
            if let script = Self.appleScript(for: builtin) {
                spawn("/usr/bin/osascript", ["-e", script], label: action.description, pattern: pattern, completion: completion)
            } else {
                completion?(performInProcess(builtin, pattern: pattern))
            }
        }
    }

    private func performInProcess(_ builtin: BuiltinAction, pattern: String) -> Bool {
        do {
            switch builtin {
            case .mediaPlayPause: try Self.postMediaKey(16) // NX_KEYTYPE_PLAY
            case .mediaNext: try Self.postMediaKey(17) // NX_KEYTYPE_NEXT
            case .mediaPrevious: try Self.postMediaKey(18) // NX_KEYTYPE_PREVIOUS
            case .outputToggleMute, .inputToggleMute:
                let result = try AudioHardware.toggleMute(input: builtin == .inputToggleMute)
                Log.info("action done", ["pattern": pattern, "action": builtin.rawValue, "device": result.device, "muted": result.muted])
                return true
            case .outputVolumeUp, .outputVolumeDown:
                let result = try AudioHardware.changeOutputVolume(by: builtin == .outputVolumeUp ? 1 / 16 : -1 / 16)
                Log.info("action done", ["pattern": pattern, "action": builtin.rawValue, "device": result.device,
                                         "volume": String(format: "%.2f", result.volume)])
                return true
            default:
                preconditionFailure("\(builtin.rawValue) runs as AppleScript")
            }
            Log.info("action done", ["pattern": pattern, "action": builtin.rawValue])
            return true
        } catch {
            Log.error("action failed", ["pattern": pattern, "action": builtin.rawValue, "error": error])
            return false
        }
    }

    static func appleScript(for builtin: BuiltinAction) -> String? {
        let (app, command): (String, String)
        switch builtin {
        case .spotifyPlayPause: (app, command) = ("Spotify", "playpause")
        case .spotifyNext: (app, command) = ("Spotify", "next track")
        case .spotifyPrevious: (app, command) = ("Spotify", "previous track")
        case .musicPlayPause: (app, command) = ("Music", "playpause")
        case .musicNext: (app, command) = ("Music", "next track")
        case .musicPrevious: (app, command) = ("Music", "previous track")
        default: return nil
        }
        // Checking first keeps a press from launching the app.
        return "if application \"\(app)\" is running then\ntell application \"\(app)\" to \(command)\nelse\nreturn \"\(app) is not running\"\nend if"
    }

    /// Posts a system media key (down and up), which macOS routes to the app that is playing.
    private static func postMediaKey(_ key: Int) throws(AudioHardwareError) {
        guard CGPreflightPostEventAccess() else {
            CGRequestPostEventAccess()
            throw AudioHardwareError(description: "no Accessibility permission to post media keys; "
                + "allow pressy in System Settings > Privacy & Security > Accessibility")
        }
        for state in [0xA, 0xB] { // key down, key up
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                                           data1: (key << 16) | (state << 8), data2: -1)
            guard let cgEvent = event?.cgEvent else { throw AudioHardwareError(description: "creating the media key event failed") }
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    private func spawn(_ executable: String, _ arguments: [String], label: String, pattern: String,
                       completion: (@MainActor (Bool) -> Void)?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PRESSY_PATTERN"] = pattern
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = OutputTail()
        pipe.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }

        let started = Date()
        process.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            let signaled = finished.terminationReason == .uncaughtSignal
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            let text = output.text
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if status == 0 && !signaled {
                        Log.info("action done", ["pattern": pattern, "action": label, "ms": millis, "output": text])
                    } else {
                        Log.error("action failed", ["pattern": pattern, "action": label, "ms": millis,
                                                    signaled ? "signal" : "exit": status, "output": text])
                    }
                    completion?(status == 0 && !signaled)
                }
            }
        }

        do { try process.run() } catch {
            Log.error("action failed", ["pattern": pattern, "action": label, "error": error.localizedDescription])
            completion?(false)
            return
        }
        let limit = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
            if process.isRunning {
                Log.error("action timeout", ["pattern": pattern, "action": label, "seconds": Int(limit)])
                process.terminate()
            }
        }
    }
}

/// Keeps the last bytes a child process wrote, for the log line. Written from the pipe's reader thread.
private final class OutputTail: @unchecked Sendable {
    private static let limit = 300
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > Self.limit { data = data.suffix(Self.limit) }
        }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
