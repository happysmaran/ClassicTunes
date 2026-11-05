import Foundation

// iTunesSD-based devices of the 3rd and 4th generation. Like the 1st/2nd generation, the
// database stores only a path per track, so the manifest that remembers which Mac song a path
// came from is shared with ShuffleLibrary. Similar implementations from the other thing.
final class ShuffleLELibrary: DeviceLibrary {
    private let base: URL
    private var database: iTunesSD_LEDatabase
    private var manifest: ShuffleManifest

    private var itunesDir: URL { base.appendingPathComponent("iPod_Control/iTunes", isDirectory: true) }
    private var databaseURL: URL { itunesDir.appendingPathComponent("iTunesSD") }
    private var manifestURL: URL { itunesDir.appendingPathComponent("ClassicTunes.manifest.json") }
    private var statsURL: URL { itunesDir.appendingPathComponent("iTunesStats") }

    init(base: URL) throws {
        self.base = base
        let dir = base.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("iTunesSD")
        database = FileManager.default.fileExists(atPath: dbURL.path)
            ? try iTunesSD_LEDatabase.parse(from: Data(contentsOf: dbURL))
            : iTunesSD_LEDatabase()
        manifest = ShuffleManifest.load(from: dir.appendingPathComponent("ClassicTunes.manifest.json"))
    }

    var entries: [DeviceEntry] {
        database.tracks.map { DeviceEntry(id: $0.filePath, path: $0.filePath, identity: manifest.tracks[$0.filePath]) }
    }

    var databaseFiles: [URL] { [databaseURL, manifestURL] }
    var supportsPlaylists: Bool { false }

    func rejectionReason(for song: Song) async -> String? {
        guard let encoding = await ClassicBackend.encoding(for: song.url),
              iTunesSD_LEDatabase.fileType(for: encoding) != nil else {
            return "\(song.url.pathExtension.uppercased()) files can't be played by this iPod"
        }
        return nil
    }

    func prepareForWrite() throws {}

    func add(_ song: Song, identity: String, placed: PlacedFile) async throws -> DeviceEntry {
        guard let encoding = await ClassicBackend.encoding(for: placed.url),
              let type = iTunesSD_LEDatabase.fileType(for: encoding) else {
            throw SyncFailure("\(song.url.pathExtension.uppercased()) files can't be played by this iPod")
        }
        var track = iTunesSD_LETrack()
        track.filePath = placed.devicePath
        track.type = type
        track.trackNumber = UInt16(clamping: song.trackNumber ?? 1)
        track.discNumber = UInt16(clamping: song.discNumber ?? 0)
        track.albumID = id(for: song.album, in: \.albums)
        track.artistID = id(for: song.artist, in: \.artists)
        database.append(track)
        manifest.tracks[placed.devicePath] = identity
        return DeviceEntry(id: placed.devicePath, path: placed.devicePath, identity: identity)
    }

    // Stable per-name ids, kept in the manifest so a song added in a later sync lands in the same
    // album group as the earlier ones.
    private func id(for name: String, in table: WritableKeyPath<ShuffleManifest, [String: UInt32]?>) -> UInt32 {
        var ids = manifest[keyPath: table] ?? [:]
        if let existing = ids[name] { return existing }
        let new = (ids.values.max().map { $0 + 1 }) ?? 0
        ids[name] = new
        manifest[keyPath: table] = ids
        return new
    }

    func remove(_ entry: DeviceEntry) throws {
        database.removeTrack(path: entry.id)
        manifest.tracks[entry.id] = nil
    }

    func writePlaylists(_ requests: [PlaylistRequest]) throws -> Int { 0 }

    func commit() throws {
        let data = database.serialise()
        // Parsed back from the bytes so a layout mistake is caught before the device sees it.
        let check = try iTunesSD_LEDatabase.parse(from: data)
        guard check.tracks.map(\.filePath) == database.tracks.map(\.filePath) else {
            throw SyncFailure("The new iTunesSD failed its own consistency check; it was not written.")
        }
        try DeviceFiles.writeVerified(data, to: databaseURL)
        try DeviceFiles.writeVerified(manifest.encoded(), to: manifestURL)
        // The device rebuilds iTunesStats when it is missing, which is how the reference writers
        // cope with the track list changing; a stale one would disagree with the new database.
        try? FileManager.default.removeItem(at: statsURL)
    }
}
