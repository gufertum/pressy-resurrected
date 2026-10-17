import AppKit
import SwiftUI

/// Renders the menu and the editor with demo data into PNGs, light and dark, for the README.
/// Draws its own windows (`cacheDisplay`), so it needs no Screen Recording permission.
@MainActor
enum Screenshots {
    static func render(into folder: URL) async {
        let model = AppModel(demo: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let appearance = NSAppearance(named: name)!
                try await capture(MenuContent(model: model), size: nil, appearance: appearance, titled: false,
                                  to: folder.appendingPathComponent("menu-\(suffix).png"))
                try await capture(ConfigEditor(model: model, initialPattern: "-"), size: NSSize(width: 820, height: 560),
                                  appearance: appearance, titled: true, to: folder.appendingPathComponent("editor-pattern-\(suffix).png"))
                try await capture(ConfigEditor(model: model), size: NSSize(width: 820, height: 560),
                                  appearance: appearance, titled: true, to: folder.appendingPathComponent("editor-general-\(suffix).png"))
            }
            print("screenshots written to \(folder.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("screenshots failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func capture(_ view: some View, size: NSSize?, appearance: NSAppearance, titled: Bool, to file: URL) async throws {
        // cacheDisplay draws views, not the window background; the menu needs one of its own.
        let host = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light))
        let contentSize = size ?? host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: contentSize),
                              styleMask: titled ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless],
                              backing: .buffered, defer: false)
        window.title = "Pressy Configuration"
        window.appearance = appearance
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        // Give SwiftUI time for onAppear, layout and the first draw.
        try await Task.sleep(for: .milliseconds(900))
        if size == nil { window.setContentSize(host.fittingSize) }
        try await Task.sleep(for: .milliseconds(300))

        let target = titled ? (host.superview ?? host) : host
        guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        target.cacheDisplay(in: target.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: file)
        window.close()
    }
}
