import Foundation

// A persistent persistence coordinator managing the reading, writing, and lifecycle migration of playlists to disk.
final class PlaylistStore {
    
    // The global singleton reference access point across the thread environment workspace.
    static let shared = PlaylistStore()

    // The local target name designating the isolated data format layout structure[span_3](start_span)[span_3](end_span).
    private let fileName = "userPlaylists.v1.json"
    
    // Legacy keys tracking older data storage points marked for active filesystem migration[span_4](start_span)[span_4](end_span).
    private let userDefaultsKeys = ["userPlaylists.v1", "playlists"]

    // Enforces the singleton design paradigm by preventing external invocation initializers[span_5](start_span)[span_5](end_span).
    private init() {}

    // Resolves the uniform resource path mapping out the Application Support subdirectory assigned to this sandbox app environment[span_6](start_span)[span_6](end_span).
    //
    // - Returns: A platform file target system url address reference, or `nil` if workspace directories fail creation hooks[span_7](start_span)[span_7](end_span).
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

    // Pulls structural array models back out from the binary file stream registers while executing legacy schema checks[span_8](start_span)[span_8](end_span).
    //
    // - Returns: A decoded matrix collection array containing the saved structural `Playlist` objects[span_9](start_span)[span_9](end_span).
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

    // Converts active memory configuration elements into structured structural notation strings and writes them to a file safely[span_10](start_span)[span_10](end_span).
    //
    // This engine utilizes atomic backup writing steps (`.atomic`) to fully insulate parameters against file corruption events during unexpected system drops[span_11](start_span)[span_11](end_span).
    //
    // - Parameter playlists: Structural content registry maps marked for physical file commitment[span_12](start_span)[span_12](end_span).
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

    // A one-time safety check tracking structural database evolution changes[span_13](start_span)[span_13](end_span).
    //
    // Evaluates whether legacy layout data vectors reside under past preference registries; if discovered, it parses, checks structural formatting stability, maps to file blocks, and clears long-term preference memory blocks[span_14](start_span)[span_14](end_span).
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
                    _ = try decoder.decode([Playlist].self, from: data)
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
