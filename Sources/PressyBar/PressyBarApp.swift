import PressyCore
import SwiftUI

@main
struct PressyBarApp: App {
    @Local private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.flashing ? "circle.circle.fill" : "circle.circle")
        }
        .menuBarExtraStyle(.window)

        Window("Pressy Configuration", id: "editor") {
            ConfigEditor(model: model)
        }
        .defaultSize(width: 760, height: 520)
    }
}

/// The window that drops down from the menu bar icon: state, live activity, current mapping.
struct MenuContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pressy").font(.headline)
                Spacer()
                if let daemon = model.daemon, model.daemonReachable {
                    Text("v\(daemon.version)").foregroundStyle(.secondary).font(.caption)
                }
            }
            status

            Divider()
            Text("Activity").font(.subheadline.bold())
            if model.activity.isEmpty {
                Text("Press the button…").foregroundStyle(.secondary).font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.activity.prefix(8)) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(item.date, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: icon(item)).foregroundStyle(item.ok ? Color.secondary : Color.red)
                            Text(item.text).lineLimit(2)
                        }
                        .font(.caption)
                    }
                }
            }

            Divider()
            Text("Configuration").font(.subheadline.bold())
            if let error = model.loadError {
                Text(error).foregroundStyle(.red).font(.caption)
            } else if model.config.patterns.isEmpty {
                Text("No patterns yet.").foregroundStyle(.secondary).font(.callout)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(model.config.sortedPatterns, id: \.self) { pattern in
                        GridRow {
                            Text(pattern).font(.body.monospaced().bold())
                            Text(model.config.patterns[pattern]!.map(\.description).joined(separator: ", then "))
                                .font(.caption).lineLimit(1)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("Edit…") {
                    openWindow(id: "editor")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",")
                Button("Restart daemon") { model.restartDaemon() }
                Spacer()
                Menu {
                    Button("Open log") { model.openLog() }
                    Button("Show config file") { model.revealConfig() }
                    Button("Reload config") { model.reload() }
                    Divider()
                    Button("Quit Pressy menu") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { model.ping() }
    }

    @ViewBuilder private var status: some View {
        if let daemon = model.daemon, model.daemonReachable {
            VStack(alignment: .leading, spacing: 2) {
                Label("Daemon running (pid \(daemon.pid))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label(daemon.inputMonitoring ? "Input Monitoring allowed" : "Input Monitoring missing - presses will not arrive",
                      systemImage: daemon.inputMonitoring ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(daemon.inputMonitoring ? Color.secondary : Color.orange)
                Label(daemon.jack ? "Pressy plugged in" : "Nothing in the headphone jack",
                      systemImage: daemon.jack ? "cable.connector" : "cable.connector.slash")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        } else {
            Label("Daemon not running - Restart daemon, or make install", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.callout)
        }
    }

    private func icon(_ item: ActivityItem) -> String {
        switch item.kind {
        case .press: "hand.tap"
        case .pattern: "waveform.path"
        case .action: item.ok ? "checkmark.circle" : "xmark.circle"
        case .info: "info.circle"
        }
    }
}
