import Foundation

/// One line per event on stderr: `<ISO time> <LEVEL> <event> key=value ...`. The LaunchAgent sends stderr to ~/Library/Logs/pressy.log.
enum Log {
    static func info(_ event: String, _ fields: KeyValuePairs<String, Any> = [:]) { write("INFO", event, fields) }
    static func warn(_ event: String, _ fields: KeyValuePairs<String, Any> = [:]) { write("WARN", event, fields) }
    static func error(_ event: String, _ fields: KeyValuePairs<String, Any> = [:]) { write("ERROR", event, fields) }

    private static func write(_ level: String, _ event: String, _ fields: KeyValuePairs<String, Any>) {
        let time = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current))
        var line = "\(time) \(level) \(event)"
        for (key, value) in fields { line += " \(key)=\(format(value))" }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func format(_ value: Any) -> String {
        let text = "\(value)"
        let plain = !text.isEmpty && text.allSatisfy { !$0.isWhitespace && $0 != "\"" && $0 != "=" }
        if plain { return text }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
