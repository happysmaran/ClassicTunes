import Foundation

// A persistent persistence coordinator managing the reading, writing, and lifecycle migration of playlists to disk.
final class PlaylistStore {

    // The global singleton reference access point across the thread environment workspace.
    static let shared = PlaylistStore()

    // The local target name designating the isolated data format layout structure.
    private let fileName = "userPlaylists.v1.json"

    // Legacy keys tracking older data storage points marked for active filesystem migration.
    private let userDefaultsKeys = ["userPlaylists.v1", "playlists"]

    // Overrides where the playlists file lives (used by tests); `nil` means Application Support.
    private let directoryOverride: URL?

    init(directory: URL? = nil) {
        self.directoryOverride = directory
    }

    // Resolves the uniform resource path mapping out the Application Support subdirectory assigned to this sandbox app environment.
    //
    // - Returns: A platform file target system url address reference, or `nil` if workspace directories fail creation hooks.
    private func playlistsFileURL() -> URL? {
        do {
            let fm = FileManager.default
            let dir: URL
            if let directoryOverride {
                dir = directoryOverride
            } else {
                let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let bundleID = Bundle.main.bundleIdentifier ?? "ClassicTunes"
                dir = appSupport.appendingPathComponent(bundleID, isDirectory: true)
            }
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir.appendingPathComponent(fileName)
        } catch {
            print("PlaylistStore: Failed to get Application Support directory: \(error)")
            return nil
        }
    }

    // The single backup copy kept beside the playlists file, refreshed before every save.
    private func backupFileURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("bak")
    }

    // Pulls structural array models back out from the binary file stream registers while executing legacy schema checks.
    //
    // A file that exists but can't be decoded is never silently treated as "no playlists": it is set
    // aside (so the next save can't overwrite it) and the backup is tried instead.
    //
    // - Returns: A decoded matrix collection array containing the saved structural `Playlist` objects.
    func load() -> [Playlist] {
        migrateIfNeeded()
        guard let fileURL = playlistsFileURL() else { return [] }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []   // First launch, or nothing saved yet.
        }

        do {
            return try decodePlaylists(at: fileURL)
        } catch {
            print("PlaylistStore: Failed to load playlists from disk: \(error)")
            quarantine(fileURL)
        }

        // The main file was unreadable; fall back to the last good copy.
        let backupURL = backupFileURL(for: fileURL)
        if FileManager.default.fileExists(atPath: backupURL.path) {
            do {
                let recovered = try decodePlaylists(at: backupURL)
                print("PlaylistStore: Recovered \(recovered.count) playlists from backup")
                return recovered
            } catch {
                print("PlaylistStore: Backup is unreadable too: \(error)")
            }
        }
        return []
    }

    // Converts active memory configuration elements into structured structural notation strings and writes them to a file safely.
    //
    // This engine utilizes atomic backup writing steps (`.atomic`) to fully insulate parameters against file corruption events during unexpected system drops.
    //
    // - Parameter playlists: Structural content registry maps marked for physical file commitment.
    func save(_ playlists: [Playlist]) {
        guard let fileURL = playlistsFileURL() else { return }
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(playlists)

            // Keep the previous version around so a bad write (or a bug) is recoverable.
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                let backupURL = backupFileURL(for: fileURL)
                try? fm.removeItem(at: backupURL)
                try? fm.copyItem(at: fileURL, to: backupURL)
            }

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

    // Decodes a playlists file and moves its songs onto path-derived IDs.
    //
    // Playlists saved by older versions hold songs with random per-scan IDs that no longer match the
    // library (or the play history); recomputing the ID from each song's path re-links them.
    private func decodePlaylists(at url: URL) throws -> [Playlist] {
        let data = try Data(contentsOf: url)
        var playlists = try JSONDecoder().decode([Playlist].self, from: data)
        for index in playlists.indices {
            playlists[index].songs = playlists[index].songs.map { $0.withStableID() }
        }
        return playlists
    }

    // Renames an unreadable playlists file out of the way instead of letting a later save replace it.
    private func quarantine(_ fileURL: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = fileURL.deletingLastPathComponent()
            .appendingPathComponent("userPlaylists.v1.unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: target)
            print("PlaylistStore: Moved unreadable playlists file to \(target.path)")
        } catch {
            print("PlaylistStore: Could not set aside unreadable playlists file: \(error)")
        }
    }

    // A one-time safety check tracking structural database evolution changes.
    //
    // Evaluates whether legacy layout data vectors reside under past preference registries; if discovered, it parses, checks structural formatting stability, maps to file blocks, and clears long-term preference memory blocks.
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
