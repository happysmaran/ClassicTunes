import Foundation
import AVKit
import AppKit

struct Song: Identifiable, Codable, Hashable {
    let id: UUID
    let url: URL
    let title: String
    let artist: String
    let album: String
    let genre: String
    var trackNumber: Int? = nil
    var discNumber: Int? = nil
    var year: String? = nil
    var composer: String? = nil
    var comment: String? = nil
    var duration: TimeInterval? = nil
    var playCount: Int = 0
    var artworkData: Data? = nil

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
        self.duration = duration
        self.playCount = playCount
        self.artworkData = artworkData
    }

    var artworkImage: NSImage? {
        guard let data = artworkData else { return nil }
        return NSImage(data: data)
    }
}


extension Song {
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
            // `.load(.value)` is the modern replacement for the deprecated `.value` property
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

        for item in allItems {
            guard let value = try? await item.load(.value) else { continue }

            if let key = item.key as? String {
                switch key {

                // Track number — stored as "n" or "n/total" in ID3
                case "TRCK":
                    trackNumber = parseLeadingInt(value as? String)

                // Disc number — stored as "n" or "n/total" in ID3
                case "TPOS":
                    discNumber = parseLeadingInt(value as? String)

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
            duration: duration,
            artworkData: artworkData
        )
    }
}

private func parseLeadingInt(_ string: String?) -> Int? {
    guard let s = string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    // Take only the part before a "/" (e.g. "3/12" → "3")
    let base = s.components(separatedBy: "/").first ?? s
    return Int(base.trimmingCharacters(in: .whitespaces))
}

private func parseMP4Pair(_ data: Data?) -> (Int, Int)? {
    guard let data = data, data.count >= 4 else { return nil }
    // Bytes 0-1 are padding; bytes 2-3 = track/disc number; bytes 4-5 = total (if present)
    let number = Int(data[2]) << 8 | Int(data[3])
    return number > 0 ? (number, data.count >= 6 ? Int(data[4]) << 8 | Int(data[5]) : 0) : nil
}

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

// this is a good idea
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
