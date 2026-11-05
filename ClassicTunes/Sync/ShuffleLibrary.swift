import Foundation

// iTunesSD-based devices (Shuffle 1G/2G). The database stores only a path per track, so which
// Mac song a record came from is kept in a small manifest next to it; without one, a record
// can't be recognized and a mirror sync replaces it.

// Remembers which Mac song each device path came from for every Shuffle generation.
struct ShuffleManifest: Codable {
    var version = 1
    var tracks: [String: String] = [:]
    // Name -> id tables for the 3rd/4th generation's album and artist grouping. Optional so
    // manifests written before they existed still decode.
    var albums: [String: UInt32]?
    var artists: [String: UInt32]?

    static func load(from url: URL) -> ShuffleManifest {
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode(ShuffleManifest.self, from: data) else { return ShuffleManifest() }
        return loaded
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

final class ShuffleLibrary: DeviceLibrary {
    private let base: URL
    private var database: iTunesSD_BEDatabase
    private var manifest: ShuffleManifest

    private var itunesDir: URL { base.appendingPathComponent("iPod_Control/iTunes", isDirectory: true) }
    private var databaseURL: URL { itunesDir.appendingPathComponent("iTunesSD") }
    private var manifestURL: URL { itunesDir.appendingPathComponent("ClassicTunes.manifest.json") }
    private var statsURL: URL { itunesDir.appendingPathComponent("iTunesStats") }

    init(base: URL) throws {
        self.base = base
        let fm = FileManager.default
        let dir = base.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("iTunesSD")
        if fm.fileExists(atPath: dbURL.path) {
            database = try iTunesSD_BEDatabase.parse(from: Data(contentsOf: dbURL))
        } else {
            database = iTunesSD_BEDatabase()
        }
        manifest = ShuffleManifest.load(from: dir.appendingPathComponent("ClassicTunes.manifest.json"))
    }

    var entries: [DeviceEntry] {
        database.tracks.map { DeviceEntry(id: $0.filePath, path: $0.filePath, identity: manifest.tracks[$0.filePath]) }
    }

    var databaseFiles: [URL] { [databaseURL, manifestURL] }
    var supportsPlaylists: Bool { false }

    func rejectionReason(for song: Song) async -> String? {
        // Shuffles cannot decode anything beyond these, and the iTunesSD file-type byte has no
        // value for the rest, so they would be written as MP3 and fail to play.
        switch await ClassicBackend.encoding(for: song.url) {
        case .mp3?, .aac?, .wav?: return nil
        default: return "\(song.url.pathExtension.uppercased()) files can't be played by this iPod"
        }
    }

    func prepareForWrite() throws {}

    func add(_ song: Song, identity: String, placed: PlacedFile) async throws -> DeviceEntry {
        var track = iTunesSD_BETrack()
        track.filePath = placed.devicePath
        track.fileType = iTunesSD_BEDatabase.fileType(for: song.url)
        track.volume = 0x59     // 89 is roughly full volume
        track.shuffleFlag = 0x01
        track.podcastFlag = 0x00
        track.stopPositionMS = await ClassicBackend.durationMS(of: song)
        database.tracks.append(track)
        manifest.tracks[placed.devicePath] = identity
        return DeviceEntry(id: placed.devicePath, path: placed.devicePath, identity: identity)
    }

    func remove(_ entry: DeviceEntry) throws {
        database.tracks.removeAll { $0.filePath == entry.id }
        manifest.tracks[entry.id] = nil
    }

    func writePlaylists(_ requests: [PlaylistRequest]) throws -> Int { 0 }

    func commit() throws {
        try DeviceFiles.writeVerified(database.serialise(), to: databaseURL)
        try DeviceFiles.writeVerified(manifest.encoded(), to: manifestURL)
        // The stats file must list exactly as many tracks as the database or the Shuffle
        // reports the library as corrupt, so play counts restart from zero after a change.
        try DeviceFiles.writeVerified(Self.emptyStats(trackCount: database.tracks.count), to: statsURL)
    }

    // iTunesStats layout (Gen 1/2 Shuffle): 18-byte header holding the track count (uint24 BE)
    // and 0x0100, then 18 bytes per track for bookmark, skip and play counts (all zero here).
    static func emptyStats(trackCount: Int) -> Data {
        var data = Data(capacity: 18 + trackCount * 18)
        data.append(UInt8((trackCount >> 16) & 0xFF))
        data.append(UInt8((trackCount >> 8) & 0xFF))
        data.append(UInt8(trackCount & 0xFF))
        data.append(contentsOf: [0x01, 0x00])
        data.append(contentsOf: [UInt8](repeating: 0, count: 13))
        data.append(contentsOf: [UInt8](repeating: 0, count: trackCount * 18))
        return data
    }
}
