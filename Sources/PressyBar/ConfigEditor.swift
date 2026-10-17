import PressyCore
import SwiftUI

/// The editor window: general settings and one page per pattern. Works on a draft; "Save & apply"
/// validates, writes the config and restarts the daemon.
struct ConfigEditor: View {
    let model: AppModel
    /// Pattern page to open first (screenshots); nil opens General.
    var initialPattern: String?

    private enum Item: Hashable { case general, pattern(UUID) }

    @Local private var draft = ConfigDraft(Config())
    @Local private var saved = ConfigDraft(Config())
    @Local private var selection: Item? = .general
    @Local private var error: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape").tag(Item.general)
                Section("Patterns") {
                    ForEach(draft.patterns) { pattern in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pattern.pattern.isEmpty ? "(empty)" : pattern.pattern).font(.body.monospaced().bold())
                            Text(pattern.actions.map { "\($0.kind) \($0.value)" }.joined(separator: ", ")).font(.caption)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(Item.pattern(pattern.id))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { addPattern() } label: { Image(systemName: "plus") }
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .disabled(selectedIndex == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch selection {
            case .pattern:
                if let index = selectedIndex {
                    PatternPage(pattern: $draft.patterns[index], model: model, draft: draft)
                }
            default:
                GeneralPage(draft: $draft, model: model)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Revert") { load() }.disabled(draft == saved)
                Button("Save & apply") { save() }.keyboardShortcut("s").disabled(draft == saved)
            }
        }
        .alert("Configuration not saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .onAppear { load() }
    }

    private var selectedIndex: Int? {
        guard case .pattern(let id) = selection else { return nil }
        return draft.patterns.firstIndex { $0.id == id }
    }

    private func load() {
        model.reload()
        draft = ConfigDraft(model.config)
        saved = draft
        if let initialPattern, let page = draft.patterns.first(where: { $0.pattern == initialPattern }) {
            selection = .pattern(page.id)
        }
        if selectedIndex == nil { selection = .general }
    }

    private func save() {
        do {
            try model.save(draft.build())
            saved = draft
        } catch {
            self.error = "\(error)"
        }
    }

    private func addPattern() {
        let pattern = PatternDraft(pattern: draft.nextFreePattern,
                                   actions: [ActionDraft(kind: "sound", value: ActionDraft.defaultValue(for: "sound"))])
        draft.patterns.append(pattern)
        selection = .pattern(pattern.id)
    }

    private func removeSelected() {
        guard let index = selectedIndex else { return }
        draft.patterns.remove(at: index)
        selection = .general
    }
}

private struct GeneralPage: View {
    @Binding var draft: ConfigDraft
    let model: AppModel

    var body: some View {
        Form {
            Section("Timing") {
                Stepper(value: $draft.longPressMs, in: 100...5000, step: 50) {
                    LabeledContent("Long press from", value: "\(draft.longPressMs) ms")
                }
                Stepper(value: $draft.sequenceGapMs, in: 100...3000, step: 50) {
                    LabeledContent("Pattern ends after", value: "\(draft.sequenceGapMs) ms silence")
                }
                Text("A press held at least the long-press time is \"-\", shorter is \".\". A pattern fires after the silence, or at once when no longer pattern is configured.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Toggle("Keep audio on the previous devices when the Pressy is plugged in", isOn: $draft.restoreAudioRoute)
                Stepper(value: $draft.actionTimeoutSeconds, in: 1...3600, step: 5) {
                    LabeledContent("Stop actions after", value: "\(draft.actionTimeoutSeconds) s")
                }
            }
            Section("Files") {
                LabeledContent("Config", value: model.configURL.path)
                LabeledContent("Log", value: "~/Library/Logs/pressy.log")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PatternPage: View {
    @Binding var pattern: PatternDraft
    let model: AppModel
    let draft: ConfigDraft
    @Local private var testOutput: String?
    @Local private var testing = false

    var body: some View {
        Form {
            Section("Pattern") {
                HStack {
                    TextField("Pattern", text: $pattern.pattern, prompt: Text(". or -"))
                        .labelsHidden()
                        .font(.title2.monospaced().bold())
                        .frame(maxWidth: 180)
                    Spacer()
                    Button("+ short") { pattern.pattern += "." }
                    Button("+ long") { pattern.pattern += "-" }
                    Button("Clear") { pattern.pattern = "" }
                }
                Text("\".\" short press, \"-\" long press, up to \(PressTiming.maxLength) presses. Example: \".-\" = click, then hold.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($pattern.actions) { $action in
                    ActionRow(action: $action, model: model) {
                        pattern.actions.removeAll { $0.id == action.id }
                    }
                }
                .onMove { pattern.actions.move(fromOffsets: $0, toOffset: $1) }
                Button { pattern.actions.append(ActionDraft(kind: "builtin", value: ActionDraft.defaultValue(for: "builtin"))) } label: {
                    Label("Add action", systemImage: "plus")
                }
            } header: {
                Text("Actions (run one after another)")
            }
            Section {
                HStack {
                    Button(testing ? "Running…" : "Test now") { Task { await test() } }.disabled(testing)
                    Text("runs these actions once, without saving").font(.caption).foregroundStyle(.secondary)
                }
                if let testOutput {
                    Text(testOutput).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        var single = draft
        single.patterns = [pattern]
        do {
            let config = try single.build()
            let result = await model.test(pattern: pattern.pattern, in: config)
            testOutput = (result.ok ? "ok\n" : "failed\n") + result.output
        } catch {
            testOutput = "\(error)"
        }
    }
}
