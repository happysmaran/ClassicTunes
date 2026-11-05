import Foundation

// Sync failures were invisible: the UI shows one line and the app console is gone after quit.
// The log goes to the Mac (survives the iPod being ejected) and to the iPod itself, so a failed
// sync can be diagnosed later from either side.
enum SyncLog {
    private static let lock = NSLock()
    private static var lines: [String] = []

    static func beginSession(_ title: String) {
        lock.lock(); lines = []; lock.unlock()
        record("=== \(title) ===")
    }

    static func record(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
        print("iPodSync: \(message)")
        lock.lock(); lines.append(line); lock.unlock()
    }

    static var macLogURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let dir = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ClassicTunes", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sync.log")
    }

    // Best effort by design: logging must never turn a good sync into a failed one.
    static func flush(deviceBase: URL?) {
        lock.lock(); let text = lines.joined(separator: "\n") + "\n"; lock.unlock()
        if let url = macLogURL, let data = text.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
        if let base = deviceBase {
            let url = base.appendingPathComponent("iPod_Control/iTunes/ClassicTunes.log")
            try? text.data(using: .utf8)?.write(to: url)
            DeviceFiles.removeAppleDouble(for: url)
        }
    }
}
