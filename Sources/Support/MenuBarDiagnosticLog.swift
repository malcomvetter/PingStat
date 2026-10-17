import Foundation

/// Append-only menu bar diagnostics (unified `log show` often returns empty without `--info` / live stream).
enum MenuBarDiagnosticLog {
    private static let folderName = "org.malcomvetter.PingStat"
    private static let fileName = "menu-bar.log"
    private static let maxBytes = 256_000

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func append(level: LogLevel, _ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) [\(level.rawValue)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let url = fileURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
        trimIfNeeded(url: url)
    }

    private static func trimIfNeeded(url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size > maxBytes
        else { return }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return }
        let keep = String(text.suffix(maxBytes / 2))
        try? keep.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
