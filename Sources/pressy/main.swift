import CoreGraphics
import Foundation
import IOKit.hid
import PressyCore

let version = "0.1.0"
let launchAgentLabel = "li.sudo.pressy"

enum Exit {
    static let ok: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 64 // EX_USAGE
    static let unavailable: Int32 = 69 // EX_UNAVAILABLE
    static let restart: Int32 = 75 // EX_TEMPFAIL; the LaunchAgent restarts on any non-zero exit
    static let config: Int32 = 78 // EX_CONFIG
}

let usage = """
    pressy \(version) - Pressy headphone-jack button daemon for macOS

    Usage:
      pressy run     [--config PATH]   seize the jack button and run the mapped actions (LaunchAgent mode)
      pressy watch   [--config PATH]   print presses and patterns, run nothing (stop the LaunchAgent first)
      pressy check   [--config PATH]   validate the config and the Shortcuts it names
      pressy reload  [--config PATH]   check, then restart the LaunchAgent \(launchAgentLabel)
      pressy trigger PATTERN [--config PATH]   run the action mapped to PATTERN once, e.g. pressy trigger ..
      pressy actions                   list the built-in actions

    Patterns: "." short press, "-" long press, up to \(PressTiming.maxLength) presses, e.g. ".", "..", "-", ".-".
    Config: $PRESSY_CONFIG, else ~/.config/pressy/config.json
    """

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("pressy: \(message)\n".utf8))
    exit(code)
}

func loadConfig(_ url: URL) -> Config {
    do { return try Config.load(from: url) } catch {
        fail("\(error)", code: Exit.config)
    }
}

/// Names of the user's Shortcuts, from `shortcuts list`; nil when the tool fails.
func installedShortcuts() -> Set<String>? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    process.arguments = ["list"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
}

func missingShortcuts(_ config: Config) -> [String]? {
    let wanted = config.patterns.values.compactMap { action -> String? in
        if case .shortcut(let name) = action { return name }
        return nil
    }
    guard !wanted.isEmpty else { return [] }
    guard let installed = installedShortcuts() else { return nil }
    return wanted.filter { !installed.contains($0) }.sorted()
}

func accessName(_ access: IOHIDAccessType) -> String {
    switch access {
    case kIOHIDAccessTypeGranted: "granted"
    case kIOHIDAccessTypeDenied: "denied"
    default: "unknown"
    }
}

@MainActor
func check(_ url: URL) -> Never {
    let config = loadConfig(url)
    guard let missing = missingShortcuts(config) else { fail("cannot list Shortcuts (/usr/bin/shortcuts list failed)", code: Exit.failure) }
    if !missing.isEmpty { fail("\(url.path): unknown Shortcuts: \(missing.map { "\"\($0)\"" }.joined(separator: ", "))", code: Exit.config) }
    print("config ok: \(url.path)")
    print(String(format: "  long press >= %.0f ms, sequence gap %.0f ms, restoreAudioRoute %@, action timeout %.0f s",
                 config.timing.longPress * 1000, config.timing.sequenceGap * 1000, "\(config.restoreAudioRoute)", config.actionTimeout))
    for pattern in config.patterns.keys.sorted(by: { ($0.count, $0) < ($1.count, $1) }) {
        print("  \(pattern.padding(toLength: 6, withPad: " ", startingAt: 0)) \(config.patterns[pattern]!)")
    }
    exit(Exit.ok)
}

@MainActor
func daemon(_ url: URL, dryRun: Bool) -> Never {
    let config: Config
    if dryRun && !FileManager.default.fileExists(atPath: url.path) {
        config = Config()
    } else {
        config = loadConfig(url)
    }
    Log.info("start", ["version": version, "pid": getpid(), "config": url.path, "patterns": config.patterns.count, "dry_run": dryRun,
                       "input_monitoring": accessName(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))])

    if !dryRun {
        switch missingShortcuts(config) {
        case nil: Log.warn("cannot list Shortcuts, not checking names")
        case let missing? where !missing.isEmpty: Log.error("unknown Shortcuts in config", ["names": missing.joined(separator: ", ")])
        default: break
        }
        let needsAccessibility = config.patterns.values.contains { if case .builtin(let b) = $0 { b.needsAccessibility } else { false } }
        if needsAccessibility && !CGPreflightPostEventAccess() {
            // Asking at start shows the prompt now instead of on the first press.
            CGRequestPostEventAccess()
            Log.warn("media.* actions need Accessibility: System Settings > Privacy & Security > Accessibility > pressy")
        }
    }

    let runner = ActionRunner(timeout: config.actionTimeout)
    let recognizer = PatternRecognizer(timing: config.timing, knownPatterns: Set(config.patterns.keys), schedule: mainQueueSchedule) { pattern in
        guard let action = config.patterns[pattern] else {
            Log.info("pattern", ["pattern": pattern, "mapped": false])
            return
        }
        Log.info("pattern", ["pattern": pattern, "action": action.description, "dry_run": dryRun])
        if !dryRun { runner.perform(action, pattern: pattern) }
    }

    let button = HeadsetButton()
    var pressedAt: TimeInterval?
    button.onEdge = { down, time in
        if down {
            pressedAt = time
            recognizer.buttonDown(at: time)
        } else {
            if let start = pressedAt { Log.info("press", ["ms": Int((time - start) * 1000)]) }
            pressedAt = nil
            recognizer.buttonUp(at: time)
        }
    }
    do { try button.open() } catch {
        Log.error("headset unavailable", ["error": error.description])
        exit(Exit.unavailable)
    }
    Log.info("listening", ["device": "Headset", "seized": true])

    // Without Input Monitoring the seized device opens fine but delivers no values. The grant only
    // applies to a fresh process, so wait for it and exit; launchd starts pressy again.
    var accessPoll: DispatchSourceTimer?
    if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        Log.warn("input monitoring not granted, presses will not arrive",
                 ["fix": "System Settings > Privacy & Security > Input Monitoring > allow pressy"])
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
            guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
            Log.info("input monitoring granted, exiting so it takes effect", ["exit": Exit.restart])
            exit(Exit.restart)
        }
        timer.resume()
        accessPoll = timer
    }

    let routeGuard = config.restoreAudioRoute && !dryRun ? AudioRouteGuard() : nil
    routeGuard?.start()

    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            Log.info("stop", ["signal": sig])
            exit(Exit.ok)
        }
        source.resume()
        signalSources.append(source)
    }

    withExtendedLifetime((button, recognizer, runner, routeGuard, signalSources, accessPoll)) {
        CFRunLoopRun()
    }
    exit(Exit.ok)
}

@MainActor
func trigger(_ pattern: String, _ url: URL) -> Never {
    let config = loadConfig(url)
    guard let action = config.patterns[pattern] else {
        fail("no action mapped to \"\(pattern)\" in \(url.path)", code: Exit.usage)
    }
    Log.info("pattern", ["pattern": pattern, "action": action.description, "trigger": true])
    ActionRunner(timeout: config.actionTimeout).perform(action, pattern: pattern) { ok in
        exit(ok ? Exit.ok : Exit.failure)
    }
    CFRunLoopRun()
    exit(Exit.failure)
}

func mainQueueSchedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
    let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    return { item.cancel() }
}

func reload(_ url: URL) -> Never {
    _ = loadConfig(url)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(launchAgentLabel)"]
    do { try process.run() } catch { fail("launchctl: \(error.localizedDescription)", code: Exit.failure) }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("launchctl kickstart failed; is the LaunchAgent installed? (make install)", code: Exit.failure) }
    print("restarted \(launchAgentLabel) with \(url.path)")
    exit(Exit.ok)
}

// MARK: - Command line

var arguments = Array(CommandLine.arguments.dropFirst())
var configURL = Config.defaultURL()
if let index = arguments.firstIndex(of: "--config") {
    guard index + 1 < arguments.count else { fail("--config needs a path", code: Exit.usage) }
    configURL = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
    arguments.removeSubrange(index...index + 1)
}

switch (arguments.first, arguments.count) {
case ("run", 1): daemon(configURL, dryRun: false)
case ("watch", 1): daemon(configURL, dryRun: true)
case ("check", 1): check(configURL)
case ("reload", 1): reload(configURL)
case ("trigger", 2): trigger(arguments[1], configURL)
case ("actions", 1):
    for builtin in BuiltinAction.allCases {
        print("\(builtin.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)) \(builtin.summary)")
    }
case ("version", 1), ("--version", 1): print(version)
case ("help", 1), ("--help", 1), ("-h", 1), (nil, _): print(usage)
default: fail("unknown command \(arguments.joined(separator: " "))\n\n\(usage)", code: Exit.usage)
}
