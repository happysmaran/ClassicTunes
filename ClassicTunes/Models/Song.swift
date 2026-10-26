import Foundation
import AVFoundation
import AppKit
import CryptoKit

// Represents a single audio track within the application along with its associated metadata and artwork.
nonisolated struct Song: Identifiable, Codable, Hashable {
    
    // Identifies the song. Derived from the file's path (see `stableID(for:)`) rather than random, so
    // play counts, history and playlist membership still match after the library is rescanned.
    var id: UUID

    // The local file system URL pointing to the audio file.
    let url: URL
    
    // The title of the track. Defaults to the filename if metadata is missing.
    var title: String
    
    // The artist who performed the track.
    var artist: String
    
    // The album name the track belongs to.
    var album: String
    
    // The musical genre of the track.
    var genre: String
    
    // The position of the track within its album or disc sequence.
    var trackNumber: Int? = nil
    
    // The disc index if the track belongs to a multi-disc set.
    var discNumber: Int? = nil
    
    // The release or recording year.
    var year: String? = nil
    
    // The composer of the piece.
    var composer: String? = nil
    
    // An optional user or encoder comment stored in the metadata.
    var comment: String? = nil
    
    // The album-level artist, used when the track artist differs from the album's primary credit (e.g. compilations, features).
    var albumArtist: String? = nil
    
    // A free-form grouping/work name, distinct from genre (e.g. a classical movement or concept grouping).
    var grouping: String? = nil
    
    // Whether this track is considered part of a various-artists compilation album.
    var compilation: Bool = false
    
    // Tempo of the track in beats per minute.
    var bpm: Int? = nil
    
    // The total duration of the track in seconds.
    var duration: TimeInterval? = nil
    
    // The number of times this song has been fully played back.
    var playCount: Int = 0
    
    // Identifies this song's artwork in `ArtworkStore`. The image bytes themselves are not part of the
    // song, so copies of a song (playlists, queues, drag payloads) stay small.
    var artworkKey: String? = nil

    // When the file was added to the library (its creation date), captured during the scan so
    // "Recently Added" doesn't have to stat every file again.
    var dateAdded: Date? = nil

    // Initializes a new Song instance with full control over metadata parameters.
    //
    // - Parameter id: Defaults to an ID derived from `url`, so the same file always gets the same ID.
    // - Parameter artworkData: Stored in `ArtworkStore`; the song keeps only the resulting key.
    init(
        id: UUID? = nil,
        url: URL,
        title: String,
        artist: String,
        album: String,
        year: String? = nil,
        genre: String,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        composer: String? = nil,
        comment: String? = nil,
        albumArtist: String? = nil,
        grouping: String? = nil,
        compilation: Bool = false,
        bpm: Int? = nil,
        duration: TimeInterval? = nil,
        playCount: Int = 0,
        artworkData: Data? = nil,
        artworkKey: String? = nil,
        dateAdded: Date? = nil
    ) {
        self.id = id ?? Song.stableID(for: url)
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.composer = composer
        self.comment = comment
        self.albumArtist = albumArtist
        self.grouping = grouping
        self.compilation = compilation
        self.bpm = bpm
        self.duration = duration
        self.playCount = playCount
        self.artworkKey = artworkData.map { ArtworkStore.shared.store($0) } ?? artworkKey
        self.dateAdded = dateAdded
    }
}

// MARK: - Stable identity

nonisolated extension Song {
    // A deterministic ID for the file at `url`: the same path always yields the same UUID.
    //
    // Song IDs used to be random per scan, so everything keyed by ID (play counts, history, playlist
    // membership) was orphaned on every relaunch. The path is normalized first so the same file
    // reached through differently-composed Unicode or a `..` segment doesn't get two identities.
    static func stableID(for url: URL) -> UUID {
        let path = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        var bytes = Array(SHA256.hash(data: Data(path.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // UUID version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // The same song with its ID recomputed from its path. Used to migrate songs that were saved
    // (in playlists) back when IDs were random.
    func withStableID() -> Song {
        var copy = self
        copy.id = Song.stableID(for: url)
        return copy
    }
}

// MARK: - Artwork

nonisolated extension Song {
    // The embedded album artwork bytes, read from (and written to) `ArtworkStore`.
    var artworkData: Data? {
        get { artworkKey.flatMap { ArtworkStore.shared.data(for: $0) } }
        set { artworkKey = newValue.map { ArtworkStore.shared.store($0) } }
    }

    // The full-size artwork image, decoded once and cached.
    var artworkImage: NSImage? {
        artworkKey.flatMap { ArtworkStore.shared.image(for: $0) }
    }

    // A downscaled artwork image for grids and small views.
    func artworkThumbnail(maxPixelSize: Int = 300) -> NSImage? {
        artworkKey.flatMap { ArtworkStore.shared.thumbnail(for: $0, maxPixelSize: maxPixelSize) }
    }
}

// MARK: - Codable

nonisolated extension Song {
    private enum CodingKeys: String, CodingKey {
        case id, url, title, artist, album, genre, trackNumber, discNumber, year, composer, comment
        case albumArtist, grouping, compilation, bpm, duration, playCount, artworkKey, dateAdded
        // Written by earlier versions, which embedded the artwork bytes in every song. Read-only.
        case legacyArtworkData = "artworkData"
    }

    // Tolerant decoding: every field added after the first release is optional on disk, so a file
    // saved by an older version still loads instead of failing (and discarding the whole playlist
    // file) over a missing key. Artwork embedded by older versions is moved into `ArtworkStore`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let url = try c.decode(URL.self, forKey: .url)
        let legacyArtwork = try c.decodeIfPresent(Data.self, forKey: .legacyArtworkData)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id),
            url: url,
            title: try c.decode(String.self, forKey: .title),
            artist: try c.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown Artist",
            album: try c.decodeIfPresent(String.self, forKey: .album) ?? "Unknown Album",
            year: try c.decodeIfPresent(String.self, forKey: .year),
            genre: try c.decodeIfPresent(String.self, forKey: .genre) ?? "Unknown Genre",
            trackNumber: try c.decodeIfPresent(Int.self, forKey: .trackNumber),
            discNumber: try c.decodeIfPresent(Int.self, forKey: .discNumber),
            composer: try c.decodeIfPresent(String.self, forKey: .composer),
            comment: try c.decodeIfPresent(String.self, forKey: .comment),
            albumArtist: try c.decodeIfPresent(String.self, forKey: .albumArtist),
            grouping: try c.decodeIfPresent(String.self, forKey: .grouping),
            compilation: try c.decodeIfPresent(Bool.self, forKey: .compilation) ?? false,
            bpm: try c.decodeIfPresent(Int.self, forKey: .bpm),
            duration: try c.decodeIfPresent(TimeInterval.self, forKey: .duration),
            playCount: try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0,
            artworkData: legacyArtwork,
            artworkKey: try c.decodeIfPresent(String.self, forKey: .artworkKey),
            dateAdded: try c.decodeIfPresent(Date.self, forKey: .dateAdded)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(album, forKey: .album)
        try c.encode(genre, forKey: .genre)
        try c.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try c.encodeIfPresent(discNumber, forKey: .discNumber)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(composer, forKey: .composer)
        try c.encodeIfPresent(comment, forKey: .comment)
        try c.encodeIfPresent(albumArtist, forKey: .albumArtist)
        try c.encodeIfPresent(grouping, forKey: .grouping)
        try c.encode(compilation, forKey: .compilation)
        try c.encodeIfPresent(bpm, forKey: .bpm)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encode(playCount, forKey: .playCount)
        try c.encodeIfPresent(artworkKey, forKey: .artworkKey)
        try c.encodeIfPresent(dateAdded, forKey: .dateAdded)
    }
}

extension Song {
    // Asynchronously extracts embedded metadata from an audio file URL to construct a new `Song` entry.
    //
    // This utilizes modern `AVFoundation` async asset loading APIs to pull both tag-format-agnostic
    // common metadata and raw file format specific tags (such as ID3 and MP4 atoms) concurrently.
    //
    // - Parameters:
    //   - url: The file system path to the audio track.
    //   - dateAdded: The file's creation date, if the caller already has it from a directory scan.
    // - Returns: A fully-populated `Song` structural model. Embedded artwork is saved to `ArtworkStore`.
    // - Throws: An error if the asset cannot read structural metadata property states.
    static func load(from url: URL, dateAdded: Date? = nil) async throws -> Song {
        let asset = AVURLAsset(url: url)

        // Load duration and both metadata collections in one async call each.
        let duration     = try await asset.load(.duration).seconds
        let commonItems  = try await asset.load(.commonMetadata)   // tag-format-agnostic
        let allItems     = try await asset.load(.metadata)         // raw tag access (ID3 / MP4 / etc.)

        // Pull values out of the common keyspace first (works across MP3, AAC, FLAC, etc.)
        var title    = url.deletingPathExtension().lastPathComponent
        var artist   = "Unknown Artist"
        var album    = "Unknown Album"
        var genre    = "Unknown Genre"
        var year: String?        = nil
        var composer: String?    = nil
        var comment: String?     = nil
        var artworkData: Data?   = nil

        for item in commonItems {
            // '.load(.value)' is the modern replacement for the deprecated `.value` property
            guard let value = try? await item.load(.value) else { continue }

            switch item.commonKey {
            case .commonKeyTitle:
                title = value as? String ?? title

            case .commonKeyArtist:
                artist = value as? String ?? artist

            case .commonKeyAlbumName:
                album = value as? String ?? album

            case .commonKeyType:         // maps to genre in common keyspace
                genre = value as? String ?? genre

            case .commonKeyCreationDate:
                year = value as? String

            case .commonKeyAuthor:       // composer sometimes lands here
                composer = value as? String

            case .commonKeyArtwork:
                artworkData = value as? Data

            default:
                break
            }
        }

        var trackNumber: Int? = nil
        var discNumber: Int?  = nil
        var albumArtist: String? = nil
        var grouping: String?    = nil
        var compilation = false
        var bpm: Int? = nil

        for item in allItems {
            guard let value = try? await item.load(.value) else { continue }

            if let key = item.key as? String {
                switch key {

                // Track number — stored as "n" or "n/total" in ID3
                case "TRCK":
                    trackNumber = parseLeadingIntPair(value as? String).0

                // Disc number — stored as "n" or "n/total" in ID3
                case "TPOS":
                    discNumber = parseLeadingIntPair(value as? String).0

                // Genre (ID3 numeric codes like "(17)" or plain text)
                case "TCON":
                    if let raw = value as? String, !raw.isEmpty {
                        genre = parseID3Genre(raw)
                    }

                // Year / recording date
                case "TDRC", "TYER", "TDAT":
                    year = year ?? (value as? String)

                // Composer
                case "TCOM":
                    composer = composer ?? (value as? String)

                // Comment
                case "COMM":
                    comment = comment ?? (value as? String)

                // Album artist
                case "TPE2":
                    albumArtist = albumArtist ?? (value as? String)

                // Grouping / content group description
                case "TIT1":
                    grouping = grouping ?? (value as? String)

                // iTunes compilation flag
                case "TCMP":
                    compilation = compilation || (value as? String) == "1" || (value as? NSNumber)?.intValue == 1

                // Beats per minute
                case "TBPM":
                    bpm = bpm ?? parseLeadingIntPair(value as? String).0

                // Artwork (ID3 APIC frame)
                case "APIC":
                    artworkData = artworkData ?? (value as? Data)

                default:
                    break
                }
            }

            if let key = item.key as? NSNumber {
                switch key.uint32Value {

                // trkn  — track number: binary pair (number, total) as Apple's apps write it, or a
                // plain integer as older versions of this app wrote it
                case 0x74726B6E:
                    trackNumber = trackNumber ?? mp4TrackOrDisc(value)

                // disk  — disc number, same layouts as trkn
                case 0x6469736B:
                    discNumber = discNumber ?? mp4TrackOrDisc(value)

                // ©gen — free-text genre
                case 0xA967656E:
                    if let raw = value as? String, !raw.isEmpty {
                        genre = raw
                    }

                // gnre — predefined genre: a 1-based index into the ID3 genre list. It only fills in
                // a genre if no ©gen text was found (which always wins, whatever order atoms come in).
                case 0x676E7265:
                    if let raw = value as? String, !raw.isEmpty {
                        genre = raw
                    } else if genre == "Unknown Genre", let index = mp4Integer(value), index >= 1, index <= id3Genres.count {
                        genre = id3Genres[index - 1]
                    }

                // ©cmt — comment
                case 0xA9636D74:
                    comment = comment ?? (value as? String)

                // ©day — release date / year
                case 0xA9646179:
                    year = year ?? (value as? String)

                // ©wrt — composer
                case 0xA9777274:
                    composer = composer ?? (value as? String)

                // aART — album artist
                case 0x61415254:
                    albumArtist = albumArtist ?? (value as? String)

                // ©grp — grouping (Apple's Music app), or grup (what AVFoundation's own grouping
                // identifier writes)
                case 0xA9677270, 0x67727570:
                    grouping = grouping ?? (value as? String)

                // cpil — compilation flag
                case 0x6370696C:
                    if let num = value as? NSNumber {
                        compilation = compilation || num.intValue != 0
                    } else if let data = value as? Data, let first = data.first {
                        compilation = compilation || first != 0
                    }

                // tmpo — beats per minute
                case 0x746D706F:
                    bpm = bpm ?? mp4Integer(value)

                default:
                    break
                }
            }
        }

        // FLAC and WAV keep their tags in structures `Song.load` doesn't map above, so read those
        // files' tags directly. Values found there replace the filename/"Unknown" placeholders.
        if let embedded = EmbeddedTagReader.read(from: url) {
            title = embedded.title ?? title
            artist = embedded.artist ?? artist
            album = embedded.album ?? album
            genre = embedded.genre ?? genre
            year = embedded.year ?? year
            composer = embedded.composer ?? composer
            comment = embedded.comment ?? comment
            albumArtist = embedded.albumArtist ?? albumArtist
            grouping = embedded.grouping ?? grouping
            trackNumber = embedded.trackNumber ?? trackNumber
            discNumber = embedded.discNumber ?? discNumber
            bpm = embedded.bpm ?? bpm
            compilation = embedded.compilation ?? compilation
            artworkData = artworkData ?? embedded.artworkData
        }

        return Song(
            url: url,
            title: title,
            artist: artist,
            album: album,
            year: year,
            genre: genre,
            trackNumber: trackNumber,
            discNumber: discNumber,
            composer: composer,
            comment: comment,
            albumArtist: albumArtist,
            grouping: grouping,
            compilation: compilation,
            bpm: bpm,
            duration: duration,
            artworkData: artworkData,
            dateAdded: dateAdded
        )
    }
}

// Extracts a leading integer (and, if present, the "total" following a slash) from formatted tag
// strings, e.g. "03/12" yields (3, 12), while "03" yields (3, nil).
private func parseLeadingIntPair(_ string: String?) -> (Int?, Int?) {
    guard let s = string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return (nil, nil) }
    let parts = s.components(separatedBy: "/")
    let number = Int(parts[0].trimmingCharacters(in: .whitespaces))
    let total = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
    return (number, total)
}

// An integer MP4 atom value, whether AVFoundation presents it as a number or as raw big-endian bytes.
private func mp4Integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let data = value as? Data, (1...8).contains(data.count) {
        return data.reduce(0) { ($0 << 8) | Int($1) }
    }
    return nil
}

// The number from a track/disc atom. Apple's apps store a binary (reserved, number, total) record;
// older versions of this app stored a plain integer.
private func mp4TrackOrDisc(_ value: Any?) -> Int? {
    if let data = value as? Data, data.count >= 4 { return parseMP4Pair(data)?.0 }
    return mp4Integer(value)
}

// Decodes sequential MP4 atom binary payloads to parse position index numbers from raw data structures.
private func parseMP4Pair(_ data: Data?) -> (Int, Int)? {
    guard let data = data, data.count >= 4 else { return nil }
    // Bytes 0-1 are padding; bytes 2-3 = track/disc number; bytes 4-5 = total (if present)
    let number = Int(data[2]) << 8 | Int(data[3])
    return number > 0 ? (number, data.count >= 6 ? Int(data[4]) << 8 | Int(data[5]) : 0) : nil
}

// Resolves legacy ID3 numeric or grouped genre specifications into structural mapping identifiers.
private func parseID3Genre(_ raw: String) -> String {
    // Strip surrounding parentheses from numeric codes, e.g. "(17)" → "Rock"
    if raw.hasPrefix("("), let close = raw.firstIndex(of: ")") {
        let code = String(raw[raw.index(after: raw.startIndex)..<close])
        if let index = Int(code), index < id3Genres.count {
            return id3Genres[index]
        }
    }
    // Numeric string without parentheses
    if let index = Int(raw), index < id3Genres.count {
        return id3Genres[index]
    }
    return raw
}

// Index mapping definition for legacy ID3 tag genre designations.
private let id3Genres: [String] = [
    "Blues","Classic Rock","Country","Dance","Disco","Funk","Grunge","Hip-Hop",
    "Jazz","Metal","New Age","Oldies","Other","Pop","R&B","Rap","Reggae","Rock",
    "Techno","Industrial","Alternative","Ska","Death Metal","Pranks","Soundtrack",
    "Euro-Techno","Ambient","Trip-Hop","Vocal","Jazz+Funk","Fusion","Trance",
    "Classical","Instrumental","Acid","House","Game","Sound Clip","Gospel","Noise",
    "AlternRock","Bass","Soul","Punk","Space","Meditative","Instrumental Pop","K-Pop",
    "Instrumental Rock","Ethnic","Gothic","Darkwave","Techno-Industrial","Electronic",
    "Pop-Folk","Eurodance","Dream","Southern Rock","Comedy","Cult","Gangsta","Top 40",
    "Christian Rap","Pop/Funk","Jungle","Native American","Cabaret","New Wave",
    "Psychedelic","Rave","Showtunes","Trailer","Lo-Fi","Tribal","Acid Punk",
    "Acid Jazz","Polka","Retro","Musical","Rock & Roll","Hard Rock","Video Game"
]
