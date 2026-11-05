import Foundation

// MARK: - Public value types

enum ClassicAudioEncoding {
    case mp3, aac, alac, wav, aiff

    // The firmware identifies a track's decoder from this four-character code, not from the
    // file extension, so a wrong code makes an otherwise valid file unplayable.
    var filetypeCode: UInt32 {
        let text: String
        switch self {
        case .mp3: text = "MP3 "
        case .aac, .alac: text = "M4A "
        case .wav: text = "WAV "
        case .aiff: text = "AIFF"
        }
        return text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    var mp3Flag: UInt8 { self == .mp3 ? 1 : 0 }
    var avFlag: UInt16 { (self == .wav || self == .aiff) ? 0 : 0xFFFF }

    // MPEG audio type values (12 MP3, 51 AAC) follow libgpod's track defaults.
    var mpegAudioType: UInt16 {
        switch self {
        case .mp3: return 12
        case .aac: return 51
        default: return 0
        }
    }

    var kindDescription: String {
        switch self {
        case .mp3: return "MPEG audio file"
        case .aac: return "AAC audio file"
        case .alac: return "Apple Lossless audio file"
        case .wav: return "WAV audio file"
        case .aiff: return "AIFF audio file"
        }
    }
}

struct ClassicTrackInput {
    var title: String
    var artist: String = ""
    var album: String = ""
    var genre: String = ""
    var composer: String = ""
    var comment: String = ""
    var trackNumber: UInt32 = 0
    var discNumber: UInt32 = 0
    var year: UInt32 = 0
    var durationMS: UInt32 = 0
    var sizeBytes: UInt32 = 0
    var bitrateKbps: UInt32 = 0
    var sampleRateHz: UInt32 = 44100
    var encoding: ClassicAudioEncoding = .mp3
    var albumArtist: String = ""
    var grouping: String = ""
    var compilation = false
    var bpm: UInt32 = 0
    var playCount: UInt32 = 0
    // Lyrics stay inside the audio file; the track record only tells the firmware to look there.
    var hasLyrics = false
    var dateAdded: Date? = nil
    var modified: Date? = nil
    // Colon-separated device path, e.g. ":iPod_Control:Music:F00:ABCD.mp3".
    var location: String
}

struct ClassicDeviceTrack: Identifiable, Hashable {
    let id: UInt32
    let persistentID: UInt64
    var title: String
    var artist: String
    var album: String
    var genre: String
    var location: String
    var sizeBytes: UInt32
    var durationMS: UInt32

    // Path relative to the volume root, usable with URL.appendingPathComponent.
    var devicePath: String { location.replacingOccurrences(of: ":", with: "/") }

    var displayName: String {
        let parts = [title, artist].filter { !$0.isEmpty }
        return parts.isEmpty ? (devicePath as NSString).lastPathComponent : parts.joined(separator: " — ")
    }
}

struct ClassicDevicePlaylist: Identifiable {
    let id: UInt64
    var name: String
    var trackIDs: [UInt32]
    var isMaster: Bool
    // Folders and smart playlists are carried through untouched; ClassicTunes only edits plain ones.
    var isPlain: Bool
}

// MARK: - Document

// High-level view of an iPod's iTunesDB for devices that need no signature (hashing_scheme 0,
// e.g. 1st-gen Nano). Edits work on the existing tree rather than building a database from
// scratch, so everything the firmware or iTunes wrote that we do not understand survives.
final class ITunesDBDocument {
    private(set) var root: DBChunk

    private static let macEpochOffset: TimeInterval = 2_082_844_800

    init(data: Data) throws {
        let (chunk, _) = try DBChunk.parse(data, at: 0)
        guard chunk.magic == "mhbd" else {
            throw ITunesDBError.malformed("file does not start with an mhbd chunk")
        }
        root = chunk
    }

    func serialized() -> Data { root.serialized() }

    // MARK: Inspection

    var version: UInt32 { root.header.readLE(UInt32.self, at: 0x10) ?? 0 }
    var hashingScheme: UInt16 { root.header.readLE(UInt16.self, at: 0x30) ?? 0 }
    private var databaseID2: UInt64 { root.header.readLE(UInt64.self, at: 0x24) ?? 0 }
    private var databaseID: UInt64 { root.header.readLE(UInt64.self, at: 0x18) ?? 0 }

    func dataset(_ type: UInt32) -> DBChunk? {
        root.children.first {
            $0.magic == "mhsd" && $0.header.readLE(UInt32.self, at: 0x0C) == type
        }?.children.first
    }

    // One-line description of the layout, printed when a device is opened so that a rejected
    // write can be diagnosed from the log alone.
    var summary: String {
        var parts = ["mhbd v0x\(String(version, radix: 16)) scheme \(hashingScheme) header \(root.header.count)B"]
        for ds in root.children where ds.magic == "mhsd" {
            let type = ds.header.readLE(UInt32.self, at: 0x0C) ?? 0
            let list = ds.children.first
            parts.append("ds\(type)=\(list?.magic ?? "opaque")×\(list?.children.count ?? 0)")
        }
        if let first = dataset(1)?.children.first { parts.append("mhit header \(first.header.count)B") }
        if let master = masterPlaylist() {
            let mhodTypes = master.children
                .filter { $0.magic == "mhod" }
                .compactMap { $0.header.readLE(UInt32.self, at: 0x0C) }
            let indexes = sortTypes().map { "0x\(String($0.type, radix: 16))×\($0.count)" }
            parts.append("mhyp header \(master.header.count)B, master mhod types \(mhodTypes), indexes \(indexes)")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Gate for writes

    // Refusing is the safe default: a database that parses but is internally inconsistent can
    // make the device show an empty library, so unsupported layouts are never edited.
    func assertWritable() throws {
        guard hashingScheme == 0 else {
            throw ITunesDBError.unsupported("This iPod's database is signed (scheme \(hashingScheme)). ClassicTunes cannot sign it yet, so it will not modify it.")
        }
        // Artist records (dataset 8) have no maintenance logic yet, so a populated one would go stale.
        if !(dataset(8)?.children.isEmpty ?? true) {
            throw ITunesDBError.unsupported("This iPod's database contains artist records (\(summary)). ClassicTunes cannot keep them consistent yet, so it will not modify it.")
        }
        for index in indexMHODs() {
            let type = index.body.readLE(UInt32.self, at: 0) ?? 0
            guard !Self.rebuildableIndexTypes.contains(type) else { continue }
            throw ITunesDBError.unsupported("This iPod's library has a sorted index (type 0x\(String(type, radix: 16))) ClassicTunes cannot rebuild yet, so it will not modify it. (\(summary))")
        }
        for type in jumpTableTypes() where !Self.rebuildableIndexTypes.contains(type) {
            throw ITunesDBError.unsupported("This iPod's library has a letter-jump table (type 0x\(String(type, radix: 16))) ClassicTunes cannot rebuild yet, so it will not modify it.")
        }
        guard dataset(1) != nil, masterPlaylist() != nil else {
            throw ITunesDBError.malformed("track list or master playlist is missing")
        }
    }

    // MARK: Reading

    func tracks() -> [ClassicDeviceTrack] {
        (dataset(1)?.children ?? []).compactMap(Self.readTrack)
    }

    func playlists() -> [ClassicDevicePlaylist] {
        (dataset(2)?.children ?? []).compactMap { pl in
            guard pl.magic == "mhyp" else { return nil }
            let items = pl.children.filter { $0.magic == "mhip" && ($0.header.readLE(UInt8.self, at: 0x11) ?? 0) == 0 }
            let name = Self.title(of: pl)
            return ClassicDevicePlaylist(
                id: pl.header.readLE(UInt64.self, at: 0x1C) ?? 0,
                name: name,
                trackIDs: items.compactMap { $0.header.readLE(UInt32.self, at: 0x18) },
                isMaster: Self.isMaster(pl),
                isPlain: Self.isPlain(pl)
            )
        }
    }

    private static func title(of playlist: DBChunk) -> String {
        for child in playlist.children where child.magic == "mhod" {
            if child.header.readLE(UInt32.self, at: 0x0C) == 1 { return decodeString(child) ?? "" }
        }
        return ""
    }

    private static func isMaster(_ playlist: DBChunk) -> Bool {
        (playlist.header.readLE(UInt8.self, at: 0x14) ?? 0) != 0
    }

    // Smart rules live in MHOD 50/51 and folders in the kind flags; both are firmware-interpreted
    // structures that ClassicTunes does not author.
    private static func isPlain(_ playlist: DBChunk) -> Bool {
        guard (playlist.header.readLE(UInt16.self, at: 0x2A) ?? 0) == 0 else { return false }
        return !playlist.children.contains {
            guard $0.magic == "mhod", let type = $0.header.readLE(UInt32.self, at: 0x0C) else { return false }
            return type == 50 || type == 51
        }
    }

    func masterPlaylist() -> DBChunk? {
        dataset(2)?.children.first { $0.magic == "mhyp" && Self.isMaster($0) }
    }

    // The firmware reads playlists from dataset 3 when it exists and keeps dataset 2 as the flat
    // copy, so a track missing from either master is invisible on some code path. Every change
    // to a master therefore has to be applied to both.
    func masterPlaylists() -> [DBChunk] {
        [UInt32(2), 3].compactMap { type in
            dataset(type)?.children.first { $0.magic == "mhyp" && Self.isMaster($0) }
        }
    }

    private static let readableStringTypes: Set<UInt32> = [1, 2, 3, 4, 5]

    private static func readTrack(_ mhit: DBChunk) -> ClassicDeviceTrack? {
        guard mhit.magic == "mhit", let id = mhit.header.readLE(UInt32.self, at: 0x10) else { return nil }
        var strings: [UInt32: String] = [:]
        for mhod in mhit.children where mhod.magic == "mhod" {
            guard let type = mhod.header.readLE(UInt32.self, at: 0x0C),
                  readableStringTypes.contains(type), strings[type] == nil else { continue }
            strings[type] = decodeString(mhod)
        }
        return ClassicDeviceTrack(
            id: id,
            persistentID: mhit.header.readLE(UInt64.self, at: 0x70) ?? 0,
            title: strings[1] ?? "",
            artist: strings[4] ?? "",
            album: strings[3] ?? "",
            genre: strings[5] ?? "",
            location: strings[2] ?? "",
            sizeBytes: mhit.header.readLE(UInt32.self, at: 0x24) ?? 0,
            durationMS: mhit.header.readLE(UInt32.self, at: 0x28) ?? 0
        )
    }

    // String MHOD body: encoding (1 = UTF-16LE), byte length, two reserved words, then the text.
    private static func decodeString(_ mhod: DBChunk) -> String? {
        let body = mhod.body
        guard let encoding = body.readLE(UInt32.self, at: 0),
              let length = body.readLE(UInt32.self, at: 4),
              16 + Int(length) <= body.count else { return nil }
        let start = body.startIndex + 16
        let raw = body.subdata(in: start..<(start + Int(length)))
        return String(data: raw, encoding: encoding == 1 ? .utf16LittleEndian : .utf8)
    }

    // MARK: Editing tracks

    // Returns the new track's ID so callers can place it in playlists.
    @discardableResult
    func addTrack(_ input: ClassicTrackInput, now: Date = Date()) throws -> UInt32 {
        try assertWritable()
        guard let list = dataset(1) else {
            throw ITunesDBError.malformed("track list is missing")
        }
        let nextID = (list.children.compactMap { $0.header.readLE(UInt32.self, at: 0x10) }.max() ?? 0) + 1
        let persistentID = UInt64.random(in: 1...UInt64.max)
        let albumRecordID = try albumID(title: input.album, artist: input.albumArtist.isEmpty ? input.artist : input.albumArtist)
        list.children.append(makeTrack(input, id: nextID, persistentID: persistentID, albumID: albumRecordID, list: list, now: now))
        for each in masterPlaylists() {
            appendItem(to: each, trackID: nextID, persistentID: persistentID)
        }
        return nextID
    }

    // The id that links a track to its cover art in the ArtworkDB.
    func databaseTrackID(of trackID: UInt32) -> UInt64? {
        trackRecord(trackID)?.header.readLE(UInt64.self, at: 0x70)
    }

    // True for unknown ids so a vanished track is never queued for a pointless refresh.
    func hasArtwork(trackID: UInt32) -> Bool {
        guard let mhit = trackRecord(trackID) else { return true }
        return (mhit.header.readLE(UInt8.self, at: 0xA4) ?? 1) != 0
    }

    private func trackRecord(_ trackID: UInt32) -> DBChunk? {
        dataset(1)?.children.first { $0.header.readLE(UInt32.self, at: 0x10) == trackID }
    }

    // Marks a track as having cover art; the art itself lives in the ArtworkDB and .ithmb files.
    // Headers too short to hold the fields (very old databases) are left alone.
    func attachArtwork(trackID: UInt32, sourceSize: Int) {
        guard let mhit = trackRecord(trackID),
              mhit.header.hasField(at: 0xA4, size: 1) else { return }
        mhit.header.writeLE(UInt16(1), at: 0x7C)
        mhit.header.writeLE(UInt32(clamping: sourceSize), at: 0x80)
        mhit.header.writeLE(UInt8(1), at: 0xA4)
    }

    @discardableResult
    func removeTrack(id: UInt32) throws -> ClassicDeviceTrack? {
        try assertWritable()
        guard let list = dataset(1),
              let index = list.children.firstIndex(where: { $0.header.readLE(UInt32.self, at: 0x10) == id }) else {
            return nil
        }
        let removed = Self.readTrack(list.children[index])
        list.children.remove(at: index)
        for datasetType: UInt32 in [2, 3] {
            for playlist in dataset(datasetType)?.children ?? [] where playlist.magic == "mhyp" {
                let before = playlist.children.count
                playlist.children.removeAll {
                    $0.magic == "mhip"
                        && ($0.header.readLE(UInt8.self, at: 0x11) ?? 0) == 0
                        && $0.header.readLE(UInt32.self, at: 0x18) == id
                }
                if playlist.children.count != before { renumberPositions(in: playlist) }
            }
        }
        return removed
    }

    // MARK: Editing playlists

    // Creates the playlist, or replaces the contents of an existing plain playlist with the same
    // name. Other playlists on the device are never removed: the user may have made them in iTunes.
    func upsertPlaylist(named name: String, trackIDs: [UInt32], now: Date = Date()) throws {
        try assertWritable()
        guard dataset(2) != nil else { throw ITunesDBError.malformed("playlist list is missing") }
        // Unknown IDs are dropped so a playlist can never point at a track the device lacks.
        let persistentByID = Dictionary(tracks().map { ($0.id, $0.persistentID) }, uniquingKeysWith: { first, _ in first })
        let ids = trackIDs.filter { persistentByID[$0] != nil }

        func findExisting(in container: DBChunk) -> DBChunk? {
            container.children.first { candidate in
                candidate.magic == "mhyp" && !Self.isMaster(candidate) && Self.isPlain(candidate)
                    && Self.title(of: candidate) == name
            }
        }
        // Both datasets describe the same playlist, so they share one identity.
        let sharedID = [UInt32(2), 3].compactMap { dataset($0) }.compactMap { findExisting(in: $0) }
            .first?.header.readLE(UInt64.self, at: 0x1C) ?? UInt64.random(in: 1...UInt64.max)

        for datasetType: UInt32 in [2, 3] {
            guard let container = dataset(datasetType) else { continue }
            let existing = findExisting(in: container)
            let playlist = existing ?? makePlaylist(named: name, template: container, id: sharedID, now: now)
            // Attached before items are added because item IDs are allocated by scanning the
            // attached playlists; a detached playlist would hand every item the same ID.
            if existing == nil { container.children.append(playlist) }
            playlist.children.removeAll { $0.magic == "mhip" }
            for id in ids {
                appendItem(to: playlist, trackID: id, persistentID: persistentByID[id] ?? 0)
            }
        }
    }

    // MARK: Builders

    private func macTime(_ date: Date) -> UInt32 {
        UInt32(truncatingIfNeeded: Int64(date.timeIntervalSince1970 + Self.macEpochOffset))
    }

    // Header size follows the sibling tracks already on the device; only an empty library falls
    // back to the version table, because the firmware expects its own generation's layout.
    private func trackHeaderSize(list: DBChunk) -> Int {
        if let first = list.children.first { return first.header.count }
        switch version {
        case ...0x12: return 0x9C
        case ...0x19: return 0x148
        case ...0x2D: return 0x1F8
        default: return 0x270
        }
    }

    private func makeTrack(_ t: ClassicTrackInput, id: UInt32, persistentID: UInt64, albumID: UInt32, list: DBChunk, now: Date) -> DBChunk {
        let size = trackHeaderSize(list: list)
        var h = Data(count: size)
        h.replaceSubrange(0..<4, with: Array("mhit".utf8))
        h.writeLE(UInt32(size), at: 4)

        // Older headers end before many fields, so every write is bounds-checked.
        func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
            if h.hasField(at: offset, size: MemoryLayout<T>.size) { h.writeLE(value, at: offset) }
        }
        let stamp = macTime(now)
        let addedStamp = t.dateAdded.map(macTime) ?? stamp
        let modifiedStamp = t.modified.map(macTime) ?? stamp
        put(id, 0x10)
        put(UInt32(1), 0x14)                       // record class: ordinary file track
        put(t.encoding.filetypeCode, 0x18)
        put(t.encoding.mp3Flag, 0x1D)
        put(UInt8(t.compilation ? 1 : 0), 0x1E)
        put(modifiedStamp, 0x20)
        put(t.sizeBytes, 0x24)
        put(t.durationMS, 0x28)
        put(t.trackNumber, 0x2C)
        put(t.year, 0x34)
        put(t.bitrateKbps, 0x38)
        put(t.sampleRateHz << 16, 0x3C)            // 16.16 fixed point
        put(t.discNumber, 0x5C)
        put(t.playCount, 0x50)
        put(addedStamp, 0x68)
        put(UInt16(clamping: t.bpm), 0x7A)
        put(UInt8(t.hasLyrics ? 1 : 0), 0xB0)
        put(t.sizeBytes, 0x12C)                    // second copy of the file size, as the reference writer emits
        put(persistentID, 0x70)
        put(t.encoding.avFlag, 0x7E)
        put(Float(t.sampleRateHz).bitPattern, 0x88)
        put(t.encoding.mpegAudioType, 0x90)
        put(UInt8(2), 0xB2)                        // "not played yet"
        put(UInt32(1), 0xD0)                       // media type: audio
        put(albumID, 0x120)                        // album record this track belongs to (dataset 4)
        put(persistentID, 0xA8)                    // second copy of the track id, as iTunes writes it
        put(databaseID2, 0x124)
        // Defaults the firmware-facing writers use for fields whose meaning is not documented.
        put(UInt32(1), 0x168)
        put(UInt8(1), 0x197)
        put(UInt32(1), 0x1EC)
        put(UInt32(2), 0x20C)

        var mhods: [DBChunk] = [
            Self.stringMHOD(type: 1, t.title),
            Self.stringMHOD(type: 2, t.location),
        ]
        let optional: [(UInt32, String)] = [
            (3, t.album), (4, t.artist), (5, t.genre),
            (6, t.encoding.kindDescription), (8, t.comment), (12, t.composer),
            (13, t.grouping), (22, t.albumArtist),
        ]
        for (type, value) in optional where !value.isEmpty {
            mhods.append(Self.stringMHOD(type: type, value))
        }
        // TV show, episode and album-artist strings are present but empty on tracks written by
        // the reference implementation, so firmware that expects the slots finds them.
        for type: UInt32 in [19, 20] { mhods.append(Self.stringMHOD(type: type, "")) }
        if t.albumArtist.isEmpty { mhods.append(Self.stringMHOD(type: 22, "")) }
        return DBChunk(magic: "mhit", header: h, children: mhods)
    }

    private func makePlaylist(named name: String, template: DBChunk, id playlistID: UInt64, now: Date) -> DBChunk {
        let sibling = template.children.first { $0.magic == "mhyp" }
        let size = sibling?.header.count ?? 184
        var h = Data(count: size)
        h.replaceSubrange(0..<4, with: Array("mhyp".utf8))
        h.writeLE(UInt32(size), at: 4)
        func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
            if h.hasField(at: offset, size: MemoryLayout<T>.size) { h.writeLE(value, at: offset) }
        }
        let stamp = macTime(now)
        put(stamp, 0x18)
        put(playlistID, 0x1C)
        put(UInt16(1), 0x28)                       // one string MHOD (the title)
        put(UInt32(1), 0x2C)                       // manual sort order
        put(databaseID, 0x3C)
        put(playlistID, 0x44)
        put(stamp, 0x58)
        return DBChunk(magic: "mhyp", header: h, children: [
            Self.stringMHOD(type: 1, name),
            Self.playlistPreferencesMHOD(),
        ])
    }

    // Item IDs must be unique across the whole database, not per playlist.
    private func nextItemID() -> UInt32 {
        var maxID: UInt32 = 0
        for datasetType: UInt32 in [2, 3] {
            for playlist in dataset(datasetType)?.children ?? [] {
                for item in playlist.children where item.magic == "mhip" {
                    maxID = max(maxID, item.header.readLE(UInt32.self, at: 0x14) ?? 0)
                }
            }
        }
        return maxID + 1
    }

    private func itemHeaderSize() -> Int {
        for playlist in dataset(2)?.children ?? [] {
            if let item = playlist.children.first(where: { $0.magic == "mhip" }) { return item.header.count }
        }
        return 76
    }

    func appendItem(to playlist: DBChunk, trackID: UInt32, persistentID: UInt64) {
        let position = playlist.children.filter { $0.magic == "mhip" }.count
        let size = itemHeaderSize()
        var h = Data(count: size)
        h.replaceSubrange(0..<4, with: Array("mhip".utf8))
        h.writeLE(UInt32(size), at: 4)
        func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
            if h.hasField(at: offset, size: MemoryLayout<T>.size) { h.writeLE(value, at: offset) }
        }
        put(nextItemID(), 0x14)
        put(trackID, 0x18)
        put(persistentID, 0x2C)
        playlist.children.append(DBChunk(magic: "mhip", header: h, children: [Self.positionMHOD(position)]))
    }

    // Positions are stored per item, so removing one in the middle would leave gaps that the
    // firmware may interpret as ordering.
    private func renumberPositions(in playlist: DBChunk) {
        var position: UInt32 = 0
        for item in playlist.children where item.magic == "mhip" {
            if let mhod = item.children.first(where: { $0.header.readLE(UInt32.self, at: 0x0C) == 100 }),
               mhod.body.hasField(at: 0, size: 4) {
                mhod.body.writeLE(position, at: 0)
            }
            position += 1
        }
    }

    // MARK: MHOD builders

    static func mhodHeader(type: UInt32) -> Data {
        var h = Data(count: 24)
        h.replaceSubrange(0..<4, with: Array("mhod".utf8))
        h.writeLE(UInt32(24), at: 4)
        h.writeLE(type, at: 0x0C)
        return h
    }

    static func stringMHOD(type: UInt32, _ value: String) -> DBChunk {
        var text = Data()
        for unit in value.utf16 { text.appendLE(unit) }
        var body = Data()
        body.appendLE(UInt32(1))                   // encoding: UTF-16LE
        body.appendLE(UInt32(text.count))
        body.appendLE(UInt32(1))                   // pair-composition bypass, as iTunes writes it
        body.appendLE(UInt32(0))
        body.append(text)
        return DBChunk(magic: "mhod", header: mhodHeader(type: type), body: body)
    }

    private static func positionMHOD(_ position: Int) -> DBChunk {
        var body = Data()
        body.appendLE(UInt32(position))
        body.append(Data(count: 16))
        return DBChunk(magic: "mhod", header: mhodHeader(type: 100), body: body)
    }

    // The 0x288-byte display preferences blob libgpod writes for every user playlist; devices
    // have been observed to ignore playlists without it.
    private static func playlistPreferencesMHOD() -> DBChunk {
        var data = Data(count: 0x288)
        let words: [(Int, UInt32)] = [
            (0x30, 0x010084), (0x34, 0x05), (0x38, 0x09), (0x3C, 0x03), (0x40, 0x120001),
            (0x4C, 0x640014), (0x50, 1), (0x5C, 0x320014), (0x60, 1), (0x6C, 0x5A0014), (0x70, 1),
            (0x7C, 0x500014), (0x80, 1), (0x8C, 0x7D0015), (0x90, 1),
        ]
        for (offset, value) in words { data.writeLE(value, at: offset) }
        let header = mhodHeader(type: 100)
        data.replaceSubrange(0..<24, with: header)
        return DBChunk(magic: "mhod", header: Data(data.prefix(24)), body: Data(data.dropFirst(24)))
    }
}
