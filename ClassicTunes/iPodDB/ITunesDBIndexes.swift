import Foundation

// Devices that ship with sorted library indexes (MHOD 52 in the master playlist) and an album
// table (dataset 4) browse through those structures, not through the track list. A track that
// is in the track list but missing from an index is invisible on the iPod, so every write must
// leave all of them rebuilt. Sort rules are ported from captured iTunes output; an index type
// we have no verified rule for makes the write fail closed instead of guessing.
extension ITunesDBDocument {
    static let rebuildableIndexTypes: Set<UInt32> = [0x03, 0x04, 0x05, 0x07, 0x12, 0x23, 0x24]

    // MARK: Per-track facts the indexes depend on

    struct IndexTrack {
        var id: UInt32
        var persistentID: UInt64
        var title = "", artist = "", album = "", genre = "", composer = "", albumArtist = ""
        var sortTitle = "", sortArtist = "", sortAlbum = "", sortAlbumArtist = "", sortComposer = ""
        var disc: UInt32 = 0
        var track: UInt32 = 0
        var compilation = false
        var mediaType: UInt32 = 1
        var albumID: UInt32 = 0
        var mhit: DBChunk
    }

    private static func string(_ mhit: DBChunk, _ type: UInt32) -> String {
        guard let mhod = mhit.children.first(where: { $0.magic == "mhod" && $0.header.readLE(UInt32.self, at: 0x0C) == type }),
              let encoding = mhod.body.readLE(UInt32.self, at: 0),
              let length = mhod.body.readLE(UInt32.self, at: 4),
              mhod.body.count >= 16 + Int(length) else { return "" }
        let raw = mhod.body.subdata(in: 16..<(16 + Int(length)))
        return String(data: raw, encoding: encoding == 1 ? .utf16LittleEndian : .utf8) ?? ""
    }

    private func indexTracks() throws -> [IndexTrack] {
        guard let list = dataset(1), let master = masterPlaylist() else {
            throw ITunesDBError.malformed("track list or master playlist is missing")
        }
        var byID: [UInt32: DBChunk] = [:]
        for mhit in list.children { if let id = mhit.header.readLE(UInt32.self, at: 0x10) { byID[id] = mhit } }
        var result: [IndexTrack] = []
        for item in master.children where item.magic == "mhip" {
            guard let id = item.header.readLE(UInt32.self, at: 0x18), let mhit = byID[id] else {
                throw ITunesDBError.malformed("master playlist references a track that is not in the track list")
            }
            var t = IndexTrack(id: id, persistentID: mhit.header.readLE(UInt64.self, at: 0x70) ?? 0, mhit: mhit)
            t.title = Self.string(mhit, 1); t.album = Self.string(mhit, 3); t.artist = Self.string(mhit, 4)
            t.genre = Self.string(mhit, 5); t.composer = Self.string(mhit, 12); t.albumArtist = Self.string(mhit, 22)
            t.sortArtist = Self.string(mhit, 23); t.sortTitle = Self.string(mhit, 27); t.sortAlbum = Self.string(mhit, 28)
            t.sortAlbumArtist = Self.string(mhit, 29); t.sortComposer = Self.string(mhit, 30)
            t.track = mhit.header.readLE(UInt32.self, at: 0x2C) ?? 0
            t.disc = mhit.header.readLE(UInt32.self, at: 0x5C) ?? 0
            t.compilation = (mhit.header.readLE(UInt8.self, at: 0x1E) ?? 0) != 0
            t.mediaType = mhit.header.readLE(UInt32.self, at: 0xD0) ?? 1
            t.albumID = mhit.header.readLE(UInt32.self, at: 0x120) ?? 0
            result.append(t)
        }
        return result
    }

    // MARK: Sort keys

    private enum Part: Comparable {
        case text(String)
        case number(UInt64)

        static func < (a: Part, b: Part) -> Bool {
            switch (a, b) {
            case let (.text(x), .text(y)):
                // Code-point order, because Swift's String ordering is canonical-equivalence
                // based and would not reproduce the captured device ordering.
                return x.unicodeScalars.map(\.value).lexicographicallyPrecedes(y.unicodeScalars.map(\.value))
            case let (.number(x), .number(y)): return x < y
            case (.number, .text): return true
            case (.text, .number): return false
            }
        }
    }

    private static func lexLess(_ a: [Part], _ b: [Part]) -> Bool { a.lexicographicallyPrecedes(b) }

    // Leading articles are ignored by the device's own sort, matching iTunes.
    private static func plainText(_ value: String) -> String {
        var v = value
        if let space = v.firstIndex(of: " "), ["a", "an", "the"].contains(v[..<space].lowercased()) {
            v = String(v[v.index(after: space)...])
        }
        return v.decomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    private static func effectiveAlbumArtist(_ t: IndexTrack) -> String {
        [t.sortAlbumArtist, t.albumArtist, t.sortArtist, t.artist].first { !$0.isEmpty } ?? ""
    }

    private static func albumOrder(_ t: IndexTrack) -> [Part] {
        [.text(plainText(t.sortAlbum.isEmpty ? t.album : t.sortAlbum)), .number(UInt64(t.disc)),
         .number(UInt64(t.track)), .text(plainText(t.sortTitle.isEmpty ? t.title : t.sortTitle))]
    }

    private static func groupIdentity(_ t: IndexTrack) -> [String] {
        [t.album, t.albumArtist.isEmpty ? t.artist : t.albumArtist, String(t.compilation)]
    }

    private static func discTrack(_ t: IndexTrack) -> (UInt64, UInt64) {
        // Missing numbers sort after numbered ones; the sentinel needs 64 bits to exceed any UInt32.
        let missing: UInt64 = 0x1_0000_0000
        return (t.disc == 0 ? missing : UInt64(t.disc), t.track == 0 ? missing : UInt64(t.track))
    }

    private static func isBefore(_ a: (UInt64, UInt64), _ b: (UInt64, UInt64)) -> Bool {
        a.0 != b.0 ? a.0 < b.0 : a.1 < b.1
    }

    // Sort 4 sorts each track by its album's representative so that an album stays contiguous.
    private static func albumKeys(_ tracks: [IndexTrack]) -> [[Part]] {
        var reps: [[String]: IndexTrack] = [:]
        for t in tracks {
            let id = groupIdentity(t)
            if let previous = reps[id] {
                if (t.disc, t.track) < (previous.disc, previous.track) { reps[id] = t }
            } else { reps[id] = t }
        }
        return tracks.map { t -> [Part] in
            let id = groupIdentity(t)
            let rep = reps[id]!
            let artist = [rep.sortAlbumArtist, rep.albumArtist, rep.sortArtist, rep.artist].first { !$0.isEmpty } ?? ""
            var key: [Part] = [.text(plainText(rep.sortAlbum.isEmpty ? rep.album : rep.sortAlbum)), .text(plainText(artist))]
            for part in id { key.append(.text(part)) }
            key.append(.number(UInt64(t.disc)))
            key.append(.number(UInt64(t.track)))
            key.append(.text(plainText(t.sortTitle.isEmpty ? t.title : t.sortTitle)))
            return key
        }
    }

    private static func keys(_ tracks: [IndexTrack], kind: UInt32) throws -> [[Part]] {
        if kind == 4 { return albumKeys(tracks) }
        return try tracks.map { t -> [Part] in
            let title = Part.text(plainText(t.sortTitle.isEmpty ? t.title : t.sortTitle))
            let artist = Part.text(plainText(t.sortArtist.isEmpty ? t.artist : t.sortArtist))
            switch kind {
            case 0x03: return [title]
            case 0x05: return [artist] + albumOrder(t)
            case 0x07: return [.text(plainText(t.genre)), artist] + albumOrder(t)
            case 0x12: return [.text(plainText(t.sortComposer.isEmpty ? t.composer : t.sortComposer))] + albumOrder(t)
            case 0x23: return [.text(plainText(effectiveAlbumArtist(t)))] + albumOrder(t)
            default: throw ITunesDBError.unsupported("library index sort type 0x\(String(kind, radix: 16)) has no verified ordering rule")
            }
        }
    }

    // MARK: Sort 36 (album groups)

    // Matches the default collation profile used by the reference implementation for captured
    // device output: punctuation kept, explicit sort overrides keep a leading "the".
    private static func groupText(_ value: String, override: Bool) -> (Int, [UInt32]) {
        var v = value
        if !override, v.lowercased().hasPrefix("the ") { v = String(v.dropFirst(4)) }
        let folded = String(String.UnicodeScalarView(
            v.decomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive], locale: nil).unicodeScalars
                .filter { !CharacterSet.nonBaseCharacters.contains($0) }))
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
        let scalars = folded.unicodeScalars.map(\.value)
        guard let first = folded.unicodeScalars.first else { return (2, scalars) }
        return (CharacterSet.decimalDigits.contains(first) ? 1 : 0, scalars)
    }

    private static func groupOrderPositions(_ tracks: [IndexTrack], representatives: [UInt32: UInt64]) throws -> [Int] {
        var order: [UInt32] = []
        var members: [UInt32: [Int]] = [:]
        for (i, t) in tracks.enumerated() {
            if members[t.albumID] == nil { order.append(t.albumID) }
            members[t.albumID, default: []].append(i)
        }
        struct Key { var compilation: Bool; var artist: (Int, [UInt32]); var album: (Int, [UInt32]) }
        func less(_ a: Key, _ b: Key) -> Bool {
            if a.compilation != b.compilation { return !a.compilation }
            if a.artist.0 != b.artist.0 { return a.artist.0 < b.artist.0 }
            if a.artist.1 != b.artist.1 { return a.artist.1.lexicographicallyPrecedes(b.artist.1) }
            if a.album.0 != b.album.0 { return a.album.0 < b.album.0 }
            return a.album.1.lexicographicallyPrecedes(b.album.1)
        }
        var keyed: [(UInt32, Key)] = []
        for id in order {
            let idx = members[id]!
            let reference = representatives[id] ?? 0
            let rep: Int
            if reference != 0 {
                guard let hit = idx.first(where: { tracks[$0].persistentID == reference }) else {
                    throw ITunesDBError.unsupported("an album record points at a track outside that album")
                }
                rep = hit
            } else {
                rep = idx.min { isBefore(discTrack(tracks[$0]), discTrack(tracks[$1])) } ?? idx[0]
            }
            let t = tracks[rep]
            let hasAlbumArtist = !t.sortAlbumArtist.isEmpty || !t.albumArtist.isEmpty
            let compilation = t.compilation && !hasAlbumArtist
            let artistOverride = !t.sortAlbumArtist.isEmpty || (t.albumArtist.isEmpty && !t.sortArtist.isEmpty)
            keyed.append((id, Key(
                compilation: compilation,
                artist: groupText(compilation ? "" : effectiveAlbumArtist(t), override: artistOverride),
                album: groupText(t.sortAlbum.isEmpty ? t.album : t.sortAlbum, override: !t.sortAlbum.isEmpty))))
        }
        // Stable on ties so groups with identical sort values keep library order.
        let sortedGroups = keyed.enumerated().sorted { l, r in
            less(l.element.1, r.element.1) ? true : (less(r.element.1, l.element.1) ? false : l.offset < r.offset)
        }.map { $0.element.0 }
        var positions: [Int] = []
        for id in sortedGroups {
            let idx = members[id]!
            let ordered = idx.enumerated().sorted { l, r in
                let a = Self.discTrack(tracks[l.element]), b = Self.discTrack(tracks[r.element])
                if a != b { return Self.isBefore(a, b) }
                return l.offset < r.offset
            }.map(\.element)
            positions.append(contentsOf: ordered)
        }
        return positions
    }

    // MARK: Album records (dataset 4)

    private func albumRecords() -> [DBChunk] { dataset(4)?.children.filter { $0.magic == "mhia" } ?? [] }

    // Finds or creates the album record for a new track so its mhit can reference it.
    func albumID(title: String, artist: String) throws -> UInt32 {
        guard let list = dataset(4) else { return 0 }
        for record in albumRecords() {
            if Self.string(record, 200) == title, Self.string(record, 201) == artist,
               let id = record.header.readLE(UInt32.self, at: 0x10) { return id }
        }
        let nextID = (albumRecords().compactMap { $0.header.readLE(UInt32.self, at: 0x10) }.max() ?? 99) + 1
        let nextSQL = (albumRecords().compactMap { $0.header.readLE(UInt64.self, at: 0x14) }.max() ?? 19_999) + 1
        var h = Data(count: 88)
        h.replaceSubrange(0..<4, with: Array("mhia".utf8))
        h.writeLE(UInt32(88), at: 4)
        h.writeLE(nextID, at: 0x10)
        h.writeLE(nextSQL, at: 0x14)
        h.writeLE(UInt16(2), at: 0x1C)   // content type: audio
        list.children.append(DBChunk(magic: "mhia", header: h, children: [
            Self.stringMHOD(type: 200, title), Self.stringMHOD(type: 201, artist),
        ]))
        return nextID
    }

    // MARK: Index builders

    static func libraryIndexMHOD(sortType: UInt32) -> DBChunk {
        var body = Data()
        body.appendLE(sortType)
        body.appendLE(UInt32(0))
        body.append(Data(count: 40))
        return DBChunk(magic: "mhod", header: mhodHeader(type: 52), body: body)
    }

    static func jumpTableMHOD(sortType: UInt32) -> DBChunk {
        var body = Data()
        body.appendLE(sortType)
        body.appendLE(UInt32(0))
        body.append(Data(count: 8))
        return DBChunk(magic: "mhod", header: mhodHeader(type: 53), body: body)
    }

    func jumpTableMHODs() -> [DBChunk] {
        masterPlaylists().flatMap { master in
            master.children.filter { $0.magic == "mhod" && $0.header.readLE(UInt32.self, at: 0x0C) == 53 }
        }
    }

    // The scroll-by-letter strip: one entry per run of tracks whose sort text starts with the
    // same letter. Digits share one entry and symbols are skipped to the first letter or digit.
    private static func jumpLetter(_ part: Part?) -> UInt16 {
        guard case let .text(value)? = part, !value.isEmpty else { return 0 }
        for character in value where character.isLetter || character.isNumber {
            if character.isNumber { return UInt16(UInt8(ascii: "0")) }
            let upper = String(character).uppercased().unicodeScalars.first!.value
            if upper <= 0xFFFF { return UInt16(upper) }
        }
        return UInt16(UInt8(ascii: "0"))
    }

    // MARK: Entry point

    // Across both masters: they must carry identical indexes, so they are rebuilt together.
    func indexMHODs() -> [DBChunk] {
        masterPlaylists().flatMap { master in
            master.children.filter { $0.magic == "mhod" && $0.header.readLE(UInt32.self, at: 0x0C) == 52 }
        }
    }

    func jumpTableTypes() -> [UInt32] {
        jumpTableMHODs().map { $0.body.readLE(UInt32.self, at: 0) ?? 0 }
    }

    func sortTypes() -> [(type: UInt32, count: UInt32)] {
        let own = (masterPlaylist()?.children ?? []).filter {
            $0.magic == "mhod" && $0.header.readLE(UInt32.self, at: 0x0C) == 52
        }
        return own.map { ($0.body.readLE(UInt32.self, at: 0) ?? 0, $0.body.readLE(UInt32.self, at: 4) ?? 0) }
    }

    // Makes every other master playlist list the same tracks, in the same order, with the same
    // index slots as the dataset-2 master. Repairs databases written before both were kept in
    // step, where the firmware's preferred master was left empty.
    private func alignMasters() {
        guard let primary = masterPlaylist() else { return }
        let wanted = primary.children.filter { $0.magic == "mhip" }
        for other in masterPlaylists() where other !== primary {
            let have = other.children.filter { $0.magic == "mhip" }.map { $0.header.readLE(UInt32.self, at: 0x18) }
            if have != wanted.map({ $0.header.readLE(UInt32.self, at: 0x18) }) {
                other.children.removeAll { $0.magic == "mhip" }
                for item in wanted {
                    appendItem(
                        to: other,
                        trackID: item.header.readLE(UInt32.self, at: 0x18) ?? 0,
                        persistentID: item.header.readLE(UInt64.self, at: 0x2C) ?? 0
                    )
                }
            }
            for slot in primary.children where slot.magic == "mhod" {
                let type = slot.header.readLE(UInt32.self, at: 0x0C) ?? 0
                guard type == 52 || type == 53, let sort = slot.body.readLE(UInt32.self, at: 0) else { continue }
                let present = other.children.contains {
                    $0.magic == "mhod" && $0.header.readLE(UInt32.self, at: 0x0C) == type
                        && $0.body.readLE(UInt32.self, at: 0) == sort
                }
                if !present {
                    other.children.append(type == 52 ? Self.libraryIndexMHOD(sortType: sort) : Self.jumpTableMHOD(sortType: sort))
                }
            }
            // MHODs precede MHIPs inside a playlist.
            other.children = other.children.filter { $0.magic == "mhod" } + other.children.filter { $0.magic != "mhod" }
        }
    }

    // Must run once after the last edit and before serializing: the indexes are derived data, so
    // they are rebuilt from the master playlist rather than patched per edit.
    func finalizeForWrite() throws {
        try assertWritable()
        alignMasters()
        let tracks = try indexTracks()
        let indexes = indexMHODs()
        let hasAlbums = dataset(4) != nil
        guard !indexes.isEmpty || hasAlbums else { return }

        for t in tracks where t.mediaType > 1 {
            throw ITunesDBError.unsupported("track \"\(t.title)\" is not plain audio; indexes for podcasts and video are not supported")
        }
        if hasAlbums {
            for t in tracks where t.albumID == 0 {
                throw ITunesDBError.unsupported("track \"\(t.title)\" has no album record")
            }
        }

        // Album records: keep each record's representative current and drop empty ones.
        var representatives: [UInt32: UInt64] = [:]
        if hasAlbums, let list = dataset(4) {
            let used = Set(tracks.map(\.albumID))
            list.children.removeAll {
                $0.magic == "mhia" && !used.contains($0.header.readLE(UInt32.self, at: 0x10) ?? 0)
            }
            for record in list.children where record.magic == "mhia" {
                let id = record.header.readLE(UInt32.self, at: 0x10) ?? 0
                let members = tracks.filter { $0.albumID == id }
                if let rep = members.min(by: { Self.isBefore(Self.discTrack($0), Self.discTrack($1)) }) {
                    record.header.writeLE(rep.persistentID, at: 0x20)
                    record.header.writeLE(UInt16(members.contains { $0.compilation } ? 1 : 0), at: 0x1E)
                    representatives[id] = rep.persistentID
                }
            }
        }

        var jumpSource: [UInt32: (order: [Int], keys: [[Part]])] = [:]
        for index in indexes {
            let kind = index.body.readLE(UInt32.self, at: 0) ?? 0
            let order: [Int]
            if kind == 0x24 {
                order = try Self.groupOrderPositions(tracks, representatives: representatives)
            } else {
                let k = try Self.keys(tracks, kind: kind)
                order = tracks.indices.sorted { a, b in
                    Self.lexLess(k[a], k[b]) ? true : (Self.lexLess(k[b], k[a]) ? false : a < b)
                }
                jumpSource[kind] = (order, k)
            }
            var body = Data()
            body.appendLE(kind)
            body.appendLE(UInt32(order.count))
            // The 40 padding bytes are kept as the device wrote them.
            body.append(index.body.count >= 48 ? index.body.subdata(in: 8..<48) : Data(count: 40))
            for position in order { body.appendLE(UInt32(position)) }
            index.body = body
            index.header.writeLE(UInt32(24 + body.count), at: 8)
        }

        for jump in jumpTableMHODs() {
            let kind = jump.body.readLE(UInt32.self, at: 0) ?? 0
            let source: (order: [Int], keys: [[Part]])
            if let known = jumpSource[kind] {
                source = known
            } else {
                let k = try Self.keys(tracks, kind: kind)
                source = (tracks.indices.sorted { a, b in
                    Self.lexLess(k[a], k[b]) ? true : (Self.lexLess(k[b], k[a]) ? false : a < b)
                }, k)
            }
            var runs: [(letter: UInt16, start: Int, count: Int)] = []
            for (rank, position) in source.order.enumerated() {
                let letter = Self.jumpLetter(source.keys[position].first)
                if let last = runs.last, last.letter == letter {
                    runs[runs.count - 1].count += 1
                } else {
                    runs.append((letter, rank, 1))
                }
            }
            var body = Data()
            body.appendLE(kind)
            body.appendLE(UInt32(runs.count))
            body.append(jump.body.count >= 16 ? jump.body.subdata(in: 8..<16) : Data(count: 8))
            for run in runs {
                body.appendLE(run.letter)
                body.appendLE(UInt16(0))
                body.appendLE(UInt32(run.start))
                body.appendLE(UInt32(run.count))
            }
            jump.body = body
            jump.header.writeLE(UInt32(24 + body.count), at: 8)
        }
    }
}
