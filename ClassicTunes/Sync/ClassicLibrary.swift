import Foundation

// iTunesDB-based devices (Mini, Nano, Classic, Photo/Video). Tracks carry their own metadata,
// so identities come straight from the database and no manifest is needed.
final class ClassicLibrary: DeviceLibrary {
    private let base: URL
    private var document: ITunesDBDocument
    private var idByIdentity: [String: UInt32] = [:]
    private var knownEntries: [DeviceEntry]
    // nil when the iPod has no ArtworkDB we can extend; songs then sync without covers.
    private let artwork: ArtworkDatabase?

    // HASH58 databases (Classic, Nano 3G/4G) are keyed from this; nil when the iPod doesn't say.
    private let firewireGUID: Data?

    init(base: URL, fallbackArtworkFormats: [ArtworkFormat] = [], usbSerial: String? = nil) throws {
        self.base = base
        firewireGUID = ITunesDBSigning.firewireGUID(base: base) ?? usbSerial.flatMap(ITunesDBSigning.parseGUID)
        artwork = ArtworkDatabase(base: base, fallbackFormats: fallbackArtworkFormats)
        document = try ClassicBackend.loadDocument(base: base)
        // A database written by newer software than the iPod's firmware understands is read as
        // empty. With nothing in it to lose, replace it with one of the firmware's own version.
        if document.tracks().isEmpty,
           let supported = Self.supportedDatabaseVersion(base: base),
           supported <= ITunesDBTemplate.maximumVersion,
           document.version > supported {
            print("ClassicLibrary: replacing empty database v0x\(String(document.version, radix: 16)) with v0x\(String(supported, radix: 16)) to match the iPod")
            document = try ITunesDBTemplate.emptyDatabase(version: supported)
        }
        knownEntries = document.tracks().map { track in
            DeviceEntry(
                id: String(track.id),
                path: track.devicePath,
                identity: SyncIdentity.make(title: track.title, artist: track.artist, album: track.album, durationMS: track.durationMS)
            )
        }
        for entry in knownEntries {
            if let identity = entry.identity, idByIdentity[identity] == nil, let id = UInt32(entry.id) {
                idByIdentity[identity] = id
            }
        }
    }

    // The "DBVersion" the iPod reports about itself in SysInfoExtended.
    static func supportedDatabaseVersion(base: URL) -> UInt32? {
        let url = base.appendingPathComponent("iPod_Control/Device/SysInfoExtended")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let version = plist["DBVersion"] as? Int, version > 0 else { return nil }
        return UInt32(version)
    }

    var entries: [DeviceEntry] { knownEntries }
    var databaseFiles: [URL] { [ClassicBackend.databaseURL(base: base)] + (artwork?.databaseFiles ?? []) }
    var supportsPlaylists: Bool { true }

    func rejectionReason(for song: Song) async -> String? {
        await ClassicBackend.encoding(for: song.url) == nil
            ? "\(song.url.pathExtension.uppercased()) files can't be played by this iPod" : nil
    }

    func prepareForWrite() throws {
        try document.assertWritable()
        if document.hashingScheme == 1, firewireGUID == nil {
            throw ITunesDBError.unsupported("This iPod's database is signed and its FireWire GUID could not be read, so ClassicTunes cannot update it.")
        }
    }

    func add(_ song: Song, identity: String, placed: PlacedFile) async throws -> DeviceEntry {
        // Read from the placed file because it may be a converted copy with a different encoding.
        guard let encoding = await ClassicBackend.encoding(for: placed.url) else {
            throw SyncFailure("\(song.url.pathExtension.uppercased()) files can't be played by this iPod")
        }
        let properties = await ClassicBackend.audioProperties(for: placed.url)
        let input = ClassicTrackInput(
            title: song.title.isEmpty ? song.url.deletingPathExtension().lastPathComponent : song.title,
            artist: song.artist,
            album: song.album,
            genre: song.genre,
            composer: song.composer ?? "",
            comment: song.comment ?? "",
            trackNumber: UInt32(clamping: song.trackNumber ?? 0),
            discNumber: UInt32(clamping: song.discNumber ?? 0),
            year: UInt32(song.year?.prefix(4) ?? "") ?? 0,
            durationMS: await ClassicBackend.durationMS(of: song),
            sizeBytes: UInt32(clamping: placed.sizeBytes),
            bitrateKbps: properties.bitrateKbps,
            sampleRateHz: properties.sampleRateHz,
            encoding: encoding,
            albumArtist: song.albumArtist ?? "",
            grouping: song.grouping ?? "",
            compilation: song.compilation,
            bpm: UInt32(clamping: song.bpm ?? 0),
            playCount: UInt32(clamping: song.playCount),
            hasLyrics: await ClassicBackend.hasEmbeddedLyrics(placed.url),
            dateAdded: song.dateAdded,
            modified: (try? placed.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
            location: placed.devicePath.replacingOccurrences(of: "/", with: ":")
        )
        let id = try document.addTrack(input)
        idByIdentity[identity] = id
        // A cover that fails to convert must not fail the song; it just has no artwork.
        if let artwork, let cover = song.artworkData, let trackKey = document.databaseTrackID(of: id) {
            do {
                if let size = try artwork.add(cover, databaseTrackID: trackKey) {
                    document.attachArtwork(trackID: id, sourceSize: size)
                }
            } catch {
                print("ClassicLibrary: artwork skipped for \(song.title): \(error.localizedDescription)")
            }
        }
        let entry = DeviceEntry(id: String(id), path: placed.devicePath, identity: identity)
        knownEntries.append(entry)
        return entry
    }

    func needsRefresh(_ entry: DeviceEntry, for song: Song) -> Bool {
        guard artwork != nil, song.artworkKey != nil, let id = UInt32(entry.id) else { return false }
        return !document.hasArtwork(trackID: id)
    }

    func remove(_ entry: DeviceEntry) throws {
        guard let id = UInt32(entry.id) else { return }
        _ = try document.removeTrack(id: id)
        knownEntries.removeAll { $0.id == entry.id }
        if let identity = entry.identity, idByIdentity[identity] == id { idByIdentity[identity] = nil }
    }

    func writePlaylists(_ requests: [PlaylistRequest]) throws -> Int {
        var written = 0
        for request in requests {
            // Resolved through the on-device index so a playlist can include songs synced earlier
            // that are not part of this run's selection.
            let ids = request.identities.compactMap { idByIdentity[$0] }
            guard !ids.isEmpty else { continue }
            try document.upsertPlaylist(named: request.name, trackIDs: ids)
            written += 1
        }
        return written
    }

    func commit() throws {
        // Covers first: a failure after this point leaves unreferenced pixels, never a song that
        // claims art the device cannot find.
        try artwork?.commit()
        try document.finalizeForWrite()
        var data = document.serialized()
        if document.hashingScheme == 1, let guid = firewireGUID {
            try ITunesDBSigning.signHash58(&data, guid: guid)
        }
        // Validated from the bytes themselves, not from the in-memory tree that produced them.
        try ITunesDBDocument(data: data).validate()
        try DeviceFiles.writeVerified(data, to: ClassicBackend.databaseURL(base: base))
    }
}
