import AppKit
import Foundation
import PressyCore

/// Executes actions. A pattern's actions run one after another; child processes run asynchronously
/// with a timeout and every outcome is logged.
@MainActor
final class ActionRunner {
    /// Reported once per finished action.
    var onResult: ((_ pattern: String, _ action: Action, _ ok: Bool, _ millis: Int, _ detail: String) -> Void)?

    private let timeout: TimeInterval

    init(timeout: TimeInterval) { self.timeout = timeout }

    /// Runs `actions` in order; `completion` gets `true` when all succeeded.
    func perform(_ actions: [Action], pattern: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let first = actions.first else {
            completion?(true)
            return
        }
        // Strong captures on purpose: the closures end with the action, and a caller may not keep the runner.
        perform(first, pattern: pattern) { ok in
            self.perform(Array(actions.dropFirst()), pattern: pattern) { rest in completion?(ok && rest) }
        }
    }

    private func perform(_ action: Action, pattern: String, completion: @escaping @MainActor (Bool) -> Void) {
        let started = Date()
        let finish: @MainActor (Bool, String) -> Void = { ok, detail in
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            if ok {
                Log.info("action done", ["pattern": pattern, "action": action.description, "ms": millis, "output": detail])
            } else {
                Log.error("action failed", ["pattern": pattern, "action": action.description, "ms": millis, "error": detail])
            }
            self.onResult?(pattern, action, ok, millis, detail)
            completion(ok)
        }

        switch action {
        case .run(let command):
            spawn("/bin/zsh", ["-lc", command], pattern: pattern, finish: finish)
        case .script(let path):
            let expanded = SoundLibrary.expand(path)
            guard FileManager.default.isExecutableFile(atPath: expanded) else {
                return finish(false, "\(expanded) does not exist or is not executable (chmod +x)")
            }
            spawn(expanded, [], pattern: pattern, finish: finish)
        case .shortcut(let name):
            spawn("/usr/bin/shortcuts", ["run", name], pattern: pattern, finish: finish)
        case .raycast(let url):
            spawn("/usr/bin/open", ["-g", url], pattern: pattern, finish: finish)
        case .sound(let value):
            guard let file = SoundLibrary.resolve(value) else { return finish(false, "no sound \"\(value)\"") }
            // Feedback sounds must not hold up the next action: report on start, log only a failed playback.
            spawn("/usr/bin/afplay", [file.path], pattern: pattern) { ok, detail in
                if !ok { Log.error("sound failed", ["pattern": pattern, "file": file.path, "error": detail]) }
            }
            finish(true, file.lastPathComponent)
        case .keys(let combo):
            do {
                try Keyboard.post(combo)
                finish(true, combo.symbols)
            } catch {
                finish(false, error.description)
            }
        case .builtin(let builtin):
            perform(builtin, pattern: pattern, finish: finish)
        }
    }

    private func perform(_ builtin: BuiltinAction, pattern: String, finish: @escaping @MainActor (Bool, String) -> Void) {
        do {
            switch builtin.implementation {
            case .process(let executable, let arguments):
                spawn(executable, arguments, pattern: pattern, finish: finish)
            case .appleScript(let script):
                spawn("/usr/bin/osascript", ["-e", script], pattern: pattern, finish: finish)
            case .keys(let text):
                let combo = try KeyCombo(parsing: text)
                try Keyboard.post(combo)
                finish(true, combo.symbols)
            case .mediaKey(let key):
                try Keyboard.postMediaKey(key)
                finish(true, "")
            case .inProcess:
                finish(true, try performInProcess(builtin))
            }
        } catch let error as ActionError {
            finish(false, error.description)
        } catch let error as AudioHardwareError {
            finish(false, error.description)
        } catch {
            finish(false, "\(error)")
        }
    }

    private func performInProcess(_ builtin: BuiltinAction) throws -> String {
        switch builtin {
        case .outputToggleMute, .inputToggleMute:
            let result = try AudioHardware.toggleMute(input: builtin == .inputToggleMute)
            return "\(result.device) muted=\(result.muted)"
        case .outputVolumeUp, .outputVolumeDown:
            let result = try AudioHardware.changeOutputVolume(by: builtin == .outputVolumeUp ? 1 / 16 : -1 / 16)
            return String(format: "%@ volume=%.2f", result.device, result.volume)
        case .caffeinateToggle:
            return try toggleCaffeinate()
        default:
            preconditionFailure("\(builtin.rawValue) is not implemented in process")
        }
    }

    private var caffeinate: Process?

    /// `caffeinate -dims` runs until toggled off or pressy stops (`-w` ties it to pressy's pid).
    private func toggleCaffeinate() throws -> String {
        if let running = caffeinate, running.isRunning {
            running.terminate()
            caffeinate = nil
            return "awake=false"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-dims", "-w", String(getpid())]
        do { try process.run() } catch { throw ActionError(description: "caffeinate: \(error.localizedDescription)") }
        caffeinate = process
        return "awake=true"
    }

    private func spawn(_ executable: String, _ arguments: [String], pattern: String, finish: @escaping @MainActor (Bool, String) -> Void) {
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

        process.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            let signaled = finished.terminationReason == .uncaughtSignal
            let text = output.text
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if status == 0 && !signaled {
                        finish(true, text)
                    } else {
                        finish(false, "\(signaled ? "signal" : "exit") \(status)\(text.isEmpty ? "" : ": " + text)")
                    }
                }
            }
        }

        do { try process.run() } catch {
            return finish(false, error.localizedDescription)
        }
        let limit = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
            if process.isRunning {
                Log.error("action timeout", ["pattern": pattern, "executable": executable, "seconds": Int(limit)])
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
