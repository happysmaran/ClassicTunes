import Foundation

// MARK: - iTunesSD little-endian (LE) Binary Format (Gen 3 & 4 Shuffle)
//
// These Shuffles dropped the fixed-record layout of the 1st/2nd generation (see iTunesSD_BE) for a
// chunked one: a header, a track table and a playlist table, each made of tagged chunks that
// are located through absolute offsets. All integers are little-endian and paths are UTF-8.
//
//   bdhs  header, 64 bytes
//   hths  track table: 20-byte header, then one u32 file offset per track
//   rths  track record, 372 bytes
//   hphs  playlist table: 68-byte header, then one u32 file offset per playlist
//   lphs  playlist record: 44-byte header, then one u32 track index per entry
//
// References:
//   https://pypi.org/project/ipodshuffle/
//   https://github.com/raffaele-99/shuffle4g
//
// Bytes whose meaning are unknown are kept verbatim from the record that was read, because the
// firmware may depend on them and dropping them is the likeliest way to make it reject a file.

// MARK: - Records

struct iTunesSD_LETrack {
    static let recordSize = 372
    static let pathCapacity = 256

    var startPositionMS: UInt32 = 0
    // 0 plays to the end of the file.
    var stopPositionMS: UInt32 = 0
    var volumeGain: UInt32 = 0
    // See iTunesSD_LEDatabase.fileType(for:).
    var type: UInt32 = 1
    var filePath: String = ""
    // True for music, false for podcasts and audiobooks, which are skipped by shuffle.
    var dontSkipOnShuffle = true
    var remembersPlayPosition = false
    var partOfUninterruptibleAlbum = false
    // Silence the decoder is told to skip at each end; 512 samples is what the reference writers
    // use for every track.
    var pregap: UInt32 = 0x200
    var postgap: UInt32 = 0x200
    // Group tracks for the "shuffle by album/artist" feature.
    var albumID: UInt32 = 0
    var artistID: UInt32 = 0
    var trackNumber: UInt16 = 1
    var discNumber: UInt16 = 0
    // Identifies the spoken-name audio for this track; zero means it has none.
    var dbid: UInt64 = 0

    // Display name resolved later for the UI; not part of the on-disk format.
    var displayName: String = ""

    fileprivate var raw: Data?
}

struct iTunesSD_LEPlaylist {
    static let masterType: UInt32 = 1
    static let normalType: UInt32 = 2
    static let podcastType: UInt32 = 3
    static let audiobookType: UInt32 = 4

    var type: UInt32
    var dbid: UInt64 = 0
    // Positions in the database's track list.
    var trackIndexes: [Int] = []

    fileprivate var raw: Data?
}

// MARK: - Database

struct iTunesSD_LEDatabase {
    private static let headerSize = 64
    private static let tracksHeaderSize = 20
    private static let playlistsHeaderSize = 68
    private static let playlistRecordHeaderSize = 44

    static let magic = Data("bdhs".utf8)

    var maxVolume: UInt8 = 0
    // ClassicTunes does not generate these
    var enableVoiceover = false
    var tracks: [iTunesSD_LETrack] = []
    var playlists: [iTunesSD_LEPlaylist] = []

    private var rawHeader: Data?

    static func looksLikeLE(_ data: Data) -> Bool {
        data.prefix(4) == magic
    }

    // MARK: Editing

    mutating func append(_ track: iTunesSD_LETrack) {
        tracks.append(track)
    }

    // Playlists refer to tracks by position, so removing one shifts everything after it.
    mutating func removeTrack(path: String) {
        guard let removed = tracks.firstIndex(where: { $0.filePath == path }) else { return }
        tracks.remove(at: removed)
        for index in playlists.indices {
            playlists[index].trackIndexes = playlists[index].trackIndexes.compactMap {
                $0 == removed ? nil : ($0 > removed ? $0 - 1 : $0)
            }
        }
    }

    // MARK: Parse

    static func parse(from data: Data) throws -> iTunesSD_LEDatabase {
        guard data.count >= headerSize, looksLikeLE(data) else {
            throw iPodSyncError.invalidDatabase("Not a 3rd/4th generation iTunesSD file")
        }
        func u32(_ offset: Int) throws -> Int {
            guard let value = data.readLE(UInt32.self, at: offset) else {
                throw iPodSyncError.invalidDatabase("iTunesSD is truncated")
            }
            return Int(value)
        }

        var database = iTunesSD_LEDatabase()
        database.rawHeader = data.prefix(headerSize)
        database.maxVolume = data[28]
        database.enableVoiceover = data[29] != 0

        let tracksOffset = try u32(36)
        guard data.count >= tracksOffset + tracksHeaderSize,
              data[tracksOffset..<tracksOffset + 4] == Data("hths".utf8) else {
            throw iPodSyncError.invalidDatabase("iTunesSD track table is missing")
        }
        for slot in 0..<(try u32(tracksOffset + 8)) {
            let offset = try u32(tracksOffset + tracksHeaderSize + slot * 4)
            guard offset + iTunesSD_LETrack.recordSize <= data.count,
                  data[offset..<offset + 4] == Data("rths".utf8) else {
                throw iPodSyncError.invalidDatabase("iTunesSD track record \(slot) is damaged")
            }
            database.tracks.append(parseTrack(data.subdata(in: offset..<offset + iTunesSD_LETrack.recordSize)))
        }

        let playlistsOffset = try u32(40)
        guard data.count >= playlistsOffset + playlistsHeaderSize,
              data[playlistsOffset..<playlistsOffset + 4] == Data("hphs".utf8) else {
            throw iPodSyncError.invalidDatabase("iTunesSD playlist table is missing")
        }
        for slot in 0..<(try u32(playlistsOffset + 8)) {
            let offset = try u32(playlistsOffset + playlistsHeaderSize + slot * 4)
            guard offset + playlistRecordHeaderSize <= data.count,
                  data[offset..<offset + 4] == Data("lphs".utf8) else {
                throw iPodSyncError.invalidDatabase("iTunesSD playlist \(slot) is damaged")
            }
            let count = try u32(offset + 8)
            guard offset + playlistRecordHeaderSize + count * 4 <= data.count else {
                throw iPodSyncError.invalidDatabase("iTunesSD playlist \(slot) is truncated")
            }
            var playlist = iTunesSD_LEPlaylist(
                type: UInt32(try u32(offset + 24)),
                dbid: data.readLE(UInt64.self, at: offset + 16) ?? 0
            )
            playlist.raw = data.subdata(in: offset..<offset + playlistRecordHeaderSize)
            playlist.trackIndexes = try (0..<count).map { try u32(offset + playlistRecordHeaderSize + $0 * 4) }
            database.playlists.append(playlist)
        }

        let trackCount = database.tracks.count
        guard database.playlists.allSatisfy({ $0.trackIndexes.allSatisfy { $0 < trackCount } }) else {
            throw iPodSyncError.invalidDatabase("iTunesSD playlist points past the end of the track list")
        }
        return database
    }

    private static func parseTrack(_ record: Data) -> iTunesSD_LETrack {
        var track = iTunesSD_LETrack()
        track.raw = record
        track.startPositionMS = record.readLE(UInt32.self, at: 8) ?? 0
        track.stopPositionMS = record.readLE(UInt32.self, at: 12) ?? 0
        track.volumeGain = record.readLE(UInt32.self, at: 16) ?? 0
        track.type = record.readLE(UInt32.self, at: 20) ?? 0
        let name = record.subdata(in: 24..<24 + iTunesSD_LETrack.pathCapacity)
        track.filePath = String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
        track.dontSkipOnShuffle = record[284] != 0
        track.remembersPlayPosition = record[285] != 0
        track.partOfUninterruptibleAlbum = record[286] != 0
        track.pregap = record.readLE(UInt32.self, at: 288) ?? 0
        track.postgap = record.readLE(UInt32.self, at: 292) ?? 0
        track.albumID = record.readLE(UInt32.self, at: 312) ?? 0
        track.trackNumber = record.readLE(UInt16.self, at: 316) ?? 0
        track.discNumber = record.readLE(UInt16.self, at: 318) ?? 0
        track.dbid = record.readLE(UInt64.self, at: 328) ?? 0
        track.artistID = record.readLE(UInt32.self, at: 336) ?? 0
        return track
    }

    // MARK: Serialise

    // The master playlist always lists every track in order, which is how the device finds its
    // music; it is created when the database has none.
    func serialise() -> Data {
        var lists = playlists
        if let master = lists.firstIndex(where: { $0.type == iTunesSD_LEPlaylist.masterType }) {
            lists[master].trackIndexes = Array(tracks.indices)
        } else {
            lists.insert(iTunesSD_LEPlaylist(type: iTunesSD_LEPlaylist.masterType, trackIndexes: Array(tracks.indices)), at: 0)
        }

        let trackRecords = tracks.map(Self.serialiseTrack)
        let trackTableSize = Self.tracksHeaderSize + 4 * trackRecords.count
        let tracksOffset = Self.headerSize
        let playlistsOffset = tracksOffset + trackTableSize + trackRecords.reduce(0) { $0 + $1.count }

        var tracksChunk = Data()
        tracksChunk.append(Data("hths".utf8))
        tracksChunk.appendLE(UInt32(trackTableSize))
        tracksChunk.appendLE(UInt32(trackRecords.count))
        tracksChunk.append(Data(count: 8))
        var cursor = tracksOffset + trackTableSize
        for record in trackRecords {
            tracksChunk.appendLE(UInt32(cursor))
            cursor += record.count
        }
        for record in trackRecords { tracksChunk.append(record) }

        let playlistRecords = lists.map(Self.serialisePlaylist)
        let types = lists.map(\.type)
        let normal = types.filter { $0 == iTunesSD_LEPlaylist.normalType }.count
        let podcast = types.filter { $0 == iTunesSD_LEPlaylist.podcastType }.count
        let audiobook = types.filter { $0 == iTunesSD_LEPlaylist.audiobookType }.count
        let masters = types.filter { $0 == iTunesSD_LEPlaylist.masterType }.count
        let none = UInt32.max

        let playlistTableSize = Self.playlistsHeaderSize + 4 * playlistRecords.count
        var playlistsChunk = Data()
        playlistsChunk.append(Data("hphs".utf8))
        playlistsChunk.appendLE(UInt32(playlistTableSize))
        playlistsChunk.appendLE(UInt32(lists.count))
        playlistsChunk.appendLE(normal == 0 ? none : 1)
        playlistsChunk.appendLE(UInt32(normal))
        playlistsChunk.appendLE(audiobook == 0 ? none : UInt32(masters + normal + podcast))
        playlistsChunk.appendLE(UInt32(audiobook))
        playlistsChunk.appendLE(podcast == 0 ? none : UInt32(masters + normal))
        playlistsChunk.appendLE(UInt32(podcast))
        playlistsChunk.appendLE(none)
        playlistsChunk.appendLE(UInt32(0))
        playlistsChunk.appendLE(none)
        playlistsChunk.append(Data(count: 20))
        cursor = playlistsOffset + playlistTableSize
        for record in playlistRecords {
            playlistsChunk.appendLE(UInt32(cursor))
            cursor += record.count
        }
        for record in playlistRecords { playlistsChunk.append(record) }

        var header = rawHeader ?? Self.defaultHeader()
        header.writeLE(UInt32(Self.headerSize), at: 8)
        header.writeLE(UInt32(tracks.count), at: 12)
        header.writeLE(UInt32(lists.count), at: 16)
        header[28] = maxVolume
        header[29] = enableVoiceover ? 1 : 0
        // Counts the master playlist's entries, which excludes nothing for the music we write.
        header.writeLE(UInt32(tracks.count), at: 32)
        header.writeLE(UInt32(tracksOffset), at: 36)
        header.writeLE(UInt32(playlistsOffset), at: 40)

        return header + tracksChunk + playlistsChunk
    }

    private static func defaultHeader() -> Data {
        var header = Data(count: headerSize)
        header.replaceSubrange(0..<4, with: magic)
        header.replaceSubrange(4..<8, with: [0x01, 0x00, 0x01, 0x02])
        return header
    }

    private static func serialiseTrack(_ track: iTunesSD_LETrack) -> Data {
        var record = track.raw ?? Data(count: iTunesSD_LETrack.recordSize)
        record.replaceSubrange(0..<4, with: Data("rths".utf8))
        record.writeLE(UInt32(iTunesSD_LETrack.recordSize), at: 4)
        record.writeLE(track.startPositionMS, at: 8)
        record.writeLE(track.stopPositionMS, at: 12)
        record.writeLE(track.volumeGain, at: 16)
        record.writeLE(track.type, at: 20)
        // A path longer than the field would be cut mid-character and point at nothing.
        var name = Data(track.filePath.utf8)
        if name.count > iTunesSD_LETrack.pathCapacity - 1 { name = Data(name.prefix(iTunesSD_LETrack.pathCapacity - 1)) }
        name.append(Data(count: iTunesSD_LETrack.pathCapacity - name.count))
        record.replaceSubrange(24..<24 + iTunesSD_LETrack.pathCapacity, with: name)
        record[284] = track.dontSkipOnShuffle ? 1 : 0
        record[285] = track.remembersPlayPosition ? 1 : 0
        record[286] = track.partOfUninterruptibleAlbum ? 1 : 0
        record.writeLE(track.pregap, at: 288)
        record.writeLE(track.postgap, at: 292)
        record.writeLE(track.albumID, at: 312)
        record.writeLE(track.trackNumber, at: 316)
        record.writeLE(track.discNumber, at: 318)
        record.writeLE(track.dbid, at: 328)
        record.writeLE(track.artistID, at: 336)
        return record
    }

    private static func serialisePlaylist(_ playlist: iTunesSD_LEPlaylist) -> Data {
        var record = playlist.raw ?? Data(count: playlistRecordHeaderSize)
        let isMusic = playlist.type == iTunesSD_LEPlaylist.masterType || playlist.type == iTunesSD_LEPlaylist.normalType
        record.replaceSubrange(0..<4, with: Data("lphs".utf8))
        record.writeLE(UInt32(playlistRecordHeaderSize + 4 * playlist.trackIndexes.count), at: 4)
        record.writeLE(UInt32(playlist.trackIndexes.count), at: 8)
        record.writeLE(UInt32(isMusic ? playlist.trackIndexes.count : 0), at: 12)
        record.writeLE(playlist.dbid, at: 16)
        record.writeLE(playlist.type, at: 24)
        for index in playlist.trackIndexes { record.appendLE(UInt32(index)) }
        return record
    }

    // MARK: Companion files

    // MARK: File types

    // Unlike the 1st/2nd generation, these devices also play Apple Lossless and AIFF.
    static func fileType(for encoding: ClassicAudioEncoding) -> UInt32? {
        switch encoding {
        case .mp3: return 1
        case .aac: return 2
        case .wav: return 4
        case .alac: return 5
        case .aiff: return 6
        }
    }
}

// MARK: - Format detection

enum ShuffleDatabaseFormat {
    // Lists the file paths in an iTunesSD of either generation family, for views that only need
    // to show what is on the device.
    static func trackPaths(in data: Data) throws -> [String] {
        if iTunesSD_LEDatabase.looksLikeLE(data) {
            return try iTunesSD_LEDatabase.parse(from: data).tracks.map(\.filePath)
        }
        return try iTunesSD_BEDatabase.parse(from: data).tracks.map(\.filePath)
    }
}
