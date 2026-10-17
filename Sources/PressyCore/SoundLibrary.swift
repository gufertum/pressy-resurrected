import Foundation

/// Resolves the `sound` action: a system sound name ("Glass") or a path to an audio file.
public enum SoundLibrary {
    static let folders = ["/System/Library/Sounds", "/Library/Sounds", "~/Library/Sounds"]
    static let extensions = ["aiff", "aif", "wav", "caf", "mp3", "m4a"]

    /// Names of the installed alert sounds, for pickers.
    public static func installedNames() -> [String] {
        let names = folders.flatMap { folder -> [String] in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: expand(folder))) ?? []
            return files.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .map { ($0 as NSString).deletingPathExtension }
        }
        return Array(Set(names)).sorted()
    }

    /// The file to play, or nil when the name or path does not exist.
    public static func resolve(_ value: String) -> URL? {
        if value.contains("/") {
            let path = expand(value)
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for folder in folders {
            for ext in extensions {
                let path = "\(expand(folder))/\(value).\(ext)"
                if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    public static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}
