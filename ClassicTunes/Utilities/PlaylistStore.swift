import Foundation

final class PlaylistStore {
    static let shared = PlaylistStore()

    private let fileName = "userPlaylists.v1.json"
    private let userDefaultsKeys = ["userPlaylists.v1", "playlists"]

    private init() {}

    private func playlistsFileURL() -> URL? {
        do {
            let fm = FileManager.default
            let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let bundleID = Bundle.main.bundleIdentifier ?? "ClassicTunes"
            let dir = appSupport.appendingPathComponent(bundleID, isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir.appendingPathComponent(fileName)
        } catch {
            print("PlaylistStore: Failed to get Application Support directory: \(error)")
            return nil
        }
    }

    // Public load method (handles migration if needed)
    func load() -> [Playlist] {
        migrateIfNeeded()
        guard let fileURL = playlistsFileURL() else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            return try decoder.decode([Playlist].self, from: data)
        } catch {
            // If file missing or decode fails, return empty
            if (error as NSError).domain != NSCocoaErrorDomain || (error as NSError).code != NSFileReadNoSuchFileError {
                print("PlaylistStore: Failed to load playlists from disk: \(error)")
            }
            return []
        }
    }

    // Public save method
    func save(_ playlists: [Playlist]) {
        guard let fileURL = playlistsFileURL() else { return }
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(playlists)
            try data.write(to: fileURL, options: [.atomic])
            // Ensure we do not keep oversized data in UserDefaults
            let defaults = UserDefaults.standard
            for key in userDefaultsKeys {
                if defaults.object(forKey: key) != nil {
                    defaults.removeObject(forKey: key)
                }
            }
        } catch {
            print("PlaylistStore: Failed to save playlists to disk: \(error)")
        }
    }

    // One-time migration from UserDefaults to file-based storage
    private func migrateIfNeeded() {
        guard let fileURL = playlistsFileURL() else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) { return }

        let defaults = UserDefaults.standard
        for key in userDefaultsKeys {
            if let data = defaults.data(forKey: key) {
                do {
                    // Validate by decoding before writing to disk
                    let decoder = JSONDecoder()
                    let loaded = try decoder.decode([Playlist].self, from: data)
                    try data.write(to: fileURL, options: [.atomic])
                    // Clear the large value from UserDefaults after successful migration
                    defaults.removeObject(forKey: key)
                    print("PlaylistStore: Migrated playlists from UserDefaults key '\(key)' to \(fileURL.path)")
                    return
                } catch {
                    print("PlaylistStore: Migration decode failed for key '\(key)': \(error)")
                    continue
                }
            }
        }
    }
}
