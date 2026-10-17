import AppKit
import CoreGraphics
import Foundation
import IOKit.hid
import PressyCore

let version = "0.4.1"
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
      pressy convert IN OUT            rewrite a config in the format of OUT's extension (.yaml / .json)
      pressy actions                   list the built-in actions

    Patterns: "." short press, "-" long press, up to \(PressTiming.maxLength) presses, e.g. ".", "..", "-", ".-".
    Config: $PRESSY_CONFIG, else ~/.config/pressy/config.yaml (or config.yml / config.json if only that exists)
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

/// Things in the config that will fail at press time: unknown Shortcuts, missing scripts and sounds,
/// no app for raycast:// links. Empty when everything is in place.
func configProblems(_ config: Config) -> [String] {
    var problems: [String] = []
    let shortcuts = config.allActions.compactMap { if case .shortcut(let name) = $0 { name } else { nil } }
    if !shortcuts.isEmpty {
        if let installed = installedShortcuts() {
            problems += shortcuts.filter { !installed.contains($0) }.map { "unknown Shortcut \"\($0)\"" }
        } else {
            problems.append("cannot list Shortcuts (/usr/bin/shortcuts list failed)")
        }
    }
    for action in Set(config.allActions) {
        switch action {
        case .script(let path) where !FileManager.default.isExecutableFile(atPath: SoundLibrary.expand(path)):
            problems.append("script \"\(path)\" does not exist or is not executable")
        case .sound(let value) where SoundLibrary.resolve(value) == nil:
            problems.append("no sound \"\(value)\" (a name from /System/Library/Sounds or a file path)")
        case .raycast(let link) where URL(string: link).flatMap(NSWorkspace.shared.urlForApplication(toOpen:)) == nil:
            problems.append("no app opens \"\(link)\"; is Raycast installed?")
        default: break
        }
    }
    return problems.sorted()
}

/// IOHIDCheckAccess keeps answering "not granted" inside a process that started without the
/// permission (macOS 27), so a fresh `pressy input-access` is asked instead.
func inputMonitoringGrantedInFreshProcess() -> Bool {
    guard let executable = Bundle.main.executableURL else { return false }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["input-access"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
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
    let problems = configProblems(config)
    if !problems.isEmpty { fail("\(url.path):\n  " + problems.joined(separator: "\n  "), code: Exit.config) }
    print("config ok: \(url.path)")
    print(String(format: "  long press >= %.0f ms, sequence gap %.0f ms, restoreAudioRoute %@, action timeout %.0f s",
                 config.timing.longPress * 1000, config.timing.sequenceGap * 1000, "\(config.restoreAudioRoute)", config.actionTimeout))
    for pattern in config.sortedPatterns {
        let actions = config.patterns[pattern]!.map(\.description).joined(separator: ", then ")
        print("  \(pattern.padding(toLength: 6, withPad: " ", startingAt: 0)) \(actions)")
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
        for problem in configProblems(config) { Log.error("config problem", ["problem": problem]) }
        if config.allActions.contains(where: \.needsAccessibility) && !CGPreflightPostEventAccess() {
            // Asking at start shows the prompt now instead of on the first press.
            CGRequestPostEventAccess()
            Log.warn("keys and media actions need Accessibility: System Settings > Privacy & Security > Accessibility > pressy")
        }
    }

    let runner = ActionRunner(timeout: config.actionTimeout)
    let recognizer = PatternRecognizer(timing: config.timing, knownPatterns: Set(config.patterns.keys), schedule: mainQueueSchedule) { pattern in
        guard let actions = config.patterns[pattern] else {
            Log.info("pattern", ["pattern": pattern, "mapped": false])
            PressyEvent.post(PressyEvent.pattern, [PressyEvent.Key.pattern: pattern, PressyEvent.Key.actions: "", PressyEvent.Key.mapped: false])
            return
        }
        let described = actions.map(\.description).joined(separator: ", then ")
        Log.info("pattern", ["pattern": pattern, "actions": described, "dry_run": dryRun])
        PressyEvent.post(PressyEvent.pattern, [PressyEvent.Key.pattern: pattern, PressyEvent.Key.actions: described, PressyEvent.Key.mapped: true])
        if !dryRun { runner.perform(actions, pattern: pattern) }
    }

    let button = HeadsetButton()
    var pressedAt: TimeInterval?
    button.onEdge = { down, time in
        if down {
            pressedAt = time
            recognizer.buttonDown(at: time)
        } else {
            if let start = pressedAt {
                let millis = Int((time - start) * 1000)
                Log.info("press", ["ms": millis])
                PressyEvent.post(PressyEvent.press, [PressyEvent.Key.ms: millis])
            }
            pressedAt = nil
            recognizer.buttonUp(at: time)
        }
    }
    do { try button.open() } catch {
        Log.error("headset unavailable", ["error": error.description])
        exit(Exit.unavailable)
    }
    Log.info("listening", ["device": "Headset", "seized": true])

    // Without Input Monitoring the seized device opens fine but delivers no values. Once granted, presses
    // flow, but this process keeps seeing "not granted" (macOS 27), so a fresh child is polled; seen
    // granted, pressy exits and launchd starts it again with a state and log that match.
    var accessPoll: DispatchSourceTimer?
    if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        Log.warn("input monitoring not granted, presses will not arrive",
                 ["fix": "System Settings > Privacy & Security > Input Monitoring > allow pressy"])
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler {
            guard inputMonitoringGrantedInFreshProcess() else { return }
            Log.info("input monitoring granted, restarting", ["exit": Exit.restart])
            exit(Exit.restart)
        }
        timer.resume()
        accessPoll = timer
    }

    runner.onResult = { pattern, action, ok, millis, detail in
        PressyEvent.post(PressyEvent.action, [PressyEvent.Key.pattern: pattern, PressyEvent.Key.action: action.description,
                                              PressyEvent.Key.ok: ok, PressyEvent.Key.ms: millis, PressyEvent.Key.detail: detail])
    }

    let routeGuard = AudioRouteGuard(restore: config.restoreAudioRoute && !dryRun)
    let postState: @MainActor () -> Void = {
        PressyEvent.post(PressyEvent.state, [
            PressyEvent.Key.version: version, PressyEvent.Key.pid: Int(getpid()), PressyEvent.Key.config: url.path,
            PressyEvent.Key.inputMonitoring: inputMonitoringGrantedInFreshProcess(), PressyEvent.Key.jack: routeGuard.jackInUse,
        ])
    }
    routeGuard.onJackChange = { _ in postState() }
    routeGuard.start()
    // The menu bar app asks for the state when it starts.
    let pingObserver = DistributedNotificationCenter.default().addObserver(forName: PressyEvent.ping, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { postState() }
    }
    postState()

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

    withExtendedLifetime((button, recognizer, runner, routeGuard, signalSources, accessPoll, pingObserver)) {
        CFRunLoopRun()
    }
    exit(Exit.ok)
}

@MainActor
func trigger(_ pattern: String, _ url: URL) -> Never {
    let config = loadConfig(url)
    guard let actions = config.patterns[pattern] else {
        fail("no action mapped to \"\(pattern)\" in \(url.path)", code: Exit.usage)
    }
    Log.info("pattern", ["pattern": pattern, "actions": actions.map(\.description).joined(separator: ", then "), "trigger": true])
    ActionRunner(timeout: config.actionTimeout).perform(actions, pattern: pattern) { ok in
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

func convert(_ input: String, _ output: String) -> Never {
    let source = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    let target = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
    guard !FileManager.default.fileExists(atPath: target.path) else { fail("\(target.path) exists, not overwriting", code: Exit.usage) }
    let config = loadConfig(source)
    do { try config.encoded(as: ConfigFormat(url: target)).write(to: target, options: .withoutOverwriting) } catch {
        fail("\(target.path): \(error.localizedDescription)", code: Exit.failure)
    }
    print("wrote \(target.path)")
    exit(Exit.ok)
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
case ("convert", 3): convert(arguments[1], arguments[2])
case ("actions", 1):
    for builtin in BuiltinAction.allCases {
        print("\(builtin.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)) \(builtin.summary)")
    }
case ("input-access", 1): // internal: used by the daemon to see a permission granted after it started
    let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    print(accessName(access))
    exit(access == kIOHIDAccessTypeGranted ? Exit.ok : Exit.failure)
case ("version", 1), ("--version", 1): print(version)
case ("help", 1), ("--help", 1), ("-h", 1), (nil, _): print(usage)
default: fail("unknown command \(arguments.joined(separator: " "))\n\n\(usage)", code: Exit.usage)
}
