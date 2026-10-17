import AppKit
import PressyCore
import SwiftUI

/// One action of a pattern: kind picker plus the matching value editor.
struct ActionRow: View {
    @Binding var action: ActionDraft
    let model: AppModel
    let onDelete: () -> Void

    private static let kindLabels = [
        "builtin": "Built-in", "shortcut": "Shortcut", "script": "Script file", "run": "Shell command",
        "keys": "Keys", "raycast": "Raycast", "sound": "Sound",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Picker("", selection: $action.kind) {
                    ForEach(Action.kinds, id: \.self) { Text(Self.kindLabels[$0] ?? $0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                .onChange(of: action.kind) { _, kind in action.value = ActionDraft.defaultValue(for: kind) }

                valueEditor

                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            if let problem = action.problem, !action.value.isEmpty {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if action.kind == "builtin", let builtin = BuiltinAction(rawValue: action.value) {
                Text(builtin.summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var valueEditor: some View {
        switch action.kind {
        case "builtin":
            Picker("", selection: $action.value) {
                ForEach(Self.builtinCategories, id: \.self) { category in
                    Section(category) {
                        ForEach(BuiltinAction.allCases.filter { $0.category == category }, id: \.self) {
                            Text($0.rawValue).tag($0.rawValue)
                        }
                    }
                }
            }
            .labelsHidden()
        case "shortcut":
            if model.shortcuts.isEmpty {
                TextField("Shortcut name", text: $action.value)
            } else {
                Picker("", selection: $action.value) {
                    if !model.shortcuts.contains(action.value) { Text(action.value.isEmpty ? "Choose…" : action.value).tag(action.value) }
                    ForEach(model.shortcuts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            Button { Task { await model.refreshShortcuts() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Reload the list of Shortcuts")
        case "script":
            TextField("~/bin/script.sh", text: $action.value).font(.body.monospaced())
            Button("Choose…") { if let path = Self.chooseFile(title: "Choose an executable script") { action.value = path } }
        case "keys":
            KeyRecorder(value: $action.value)
            TextField("cmd+shift+4", text: $action.value).font(.body.monospaced()).frame(maxWidth: 160)
        case "raycast":
            TextField("raycast://…", text: $action.value).font(.body.monospaced())
            Menu("Examples") {
                ForEach(Self.raycastExamples, id: \.1) { name, link in Button(name) { action.value = link } }
            }
            .fixedSize()
        case "sound":
            Picker("", selection: $action.value) {
                if !SoundLibrary.installedNames().contains(action.value) { Text(action.value).tag(action.value) }
                ForEach(SoundLibrary.installedNames(), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            Button("File…") { if let path = Self.chooseFile(title: "Choose an audio file") { action.value = path } }
            Button { Self.preview(action.value) } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless)
        default:
            TextField("command", text: $action.value).font(.body.monospaced())
        }
    }

    private static let builtinCategories: [String] = {
        var seen: [String] = []
        for builtin in BuiltinAction.allCases where !seen.contains(builtin.category) { seen.append(builtin.category) }
        return seen
    }()

    static let raycastExamples = [
        ("Confetti", "confetti"),
        ("Clipboard history", "extensions/raycast/clipboard-history/clipboard-history"),
        ("Search emoji", "extensions/raycast/emoji-symbols/search-emoji-symbols"),
        ("Window: left half", "extensions/raycast/window-management/left-half"),
        ("Window: right half", "extensions/raycast/window-management/right-half"),
        ("Window: maximize", "extensions/raycast/window-management/maximize"),
    ]

    /// File picker; returns the path with the home folder written as "~".
    static func chooseFile(title: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    static func preview(_ sound: String) {
        guard let url = SoundLibrary.resolve(sound) else { return }
        NSSound(contentsOf: url, byReference: true)?.play()
    }
}

/// Click, then press a key combination; it is written in config form ("shift+cmd+4").
struct KeyRecorder: View {
    @Binding var value: String
    @Local private var monitor: Any?

    var body: some View {
        Button(monitor == nil ? (Self.symbols(value) ?? "Record") : "Press keys…") {
            monitor == nil ? start() : stop()
        }
        .help("Click, then press the key combination")
        .onDisappear { stop() }
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let combo = Self.combo(from: event)
            MainActor.assumeIsolated {
                if let combo { value = combo }
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func symbols(_ text: String) -> String? {
        (try? KeyCombo(parsing: text))?.symbols
    }

    private static let preferredNames = ["return", "tab", "space", "delete", "escape", "forwarddelete", "home", "end",
                                         "pageup", "pagedown", "help", "left", "right", "down", "up"]
        + (1...20).map { "f\($0)" }

    nonisolated static func combo(from event: NSEvent) -> String? {
        var parts: [String] = []
        let flags = event.modifierFlags
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        if let name = preferredNames.first(where: { KeyCombo.namedKeys[$0] == event.keyCode }) {
            parts.append(name)
        } else if let character = event.characters(byApplyingModifiers: [])?.lowercased(), character.count == 1 {
            parts.append(character == "+" ? "plus" : character)
        } else {
            return nil
        }
        return parts.joined(separator: "+")
    }
}
