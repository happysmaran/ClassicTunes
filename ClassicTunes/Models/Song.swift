import Foundation
import AVFoundation
import AppKit

// Represents a single audio track within the application along with its associated metadata and artwork.
struct Song: Identifiable, Codable, Hashable {
    
    // The unique identifier for the song instance.
    let id: UUID
    
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
    
    // Raw data container for the embedded album artwork image.
    var artworkData: Data? = nil

    // Initializes a new Song instance with full control over metadata parameters.
    init(
        id: UUID = UUID(),
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
        artworkData: Data? = nil
    ) {
        self.id = id
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
        self.artworkData = artworkData
    }
}

extension Song {
    // Constructs an `NSImage` representation of the embedded album artwork, if available.
    var artworkImage: NSImage? {
        guard let data = artworkData else { return nil }
        return NSImage(data: data)
    }
}

extension Song {
    // Asynchronously extracts embedded metadata from an audio file URL to construct a new `Song` entry.
    //
    // This utilizes modern `AVFoundation` async asset loading APIs to pull both tag-format-agnostic
    // common metadata and raw file format specific tags (such as ID3 and MP4 atoms) concurrently.
    //
    // - Parameter url: The file system path to the audio track.
    // - Returns: A fully-populated `Song` structural model.
    // - Throws: An error if the asset cannot read structural metadata property states.
    static func load(from url: URL) async throws -> Song {
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

                // trkn  — track number, stored as Data with two UInt16 values (number, total)
                case 0x74726B6E:
                    trackNumber = trackNumber ?? parseMP4Pair(value as? Data)?.0

                // disk  — disc number, same layout as trkn
                case 0x6469736B:
                    discNumber = discNumber ?? parseMP4Pair(value as? Data)?.0

                // ©gen or gnre
                case 0xA967656E, 0x676E7265:
                    if let raw = value as? String, !raw.isEmpty {
                        genre = raw
                    }

                // ©day — release date / year
                case 0xA9646179:
                    year = year ?? (value as? String)

                // ©wrt — composer
                case 0xA9777274:
                    composer = composer ?? (value as? String)

                // aART — album artist
                case 0x61415254:
                    albumArtist = albumArtist ?? (value as? String)

                // ©grp — grouping
                case 0xA9677270:
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
                    bpm = bpm ?? (value as? NSNumber)?.intValue

                default:
                    break
                }
            }
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
            artworkData: artworkData
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
