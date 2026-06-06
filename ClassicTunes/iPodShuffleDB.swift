import Foundation
import CryptoKit

// MARK: - iTunesSD Binary Format (Gen 1 & 2 Shuffle)
//
// File layout at /iPod_Control/iTunes/iTunesSD:
//
//   [Header — 18 bytes]
//   [Track Entry — 558 bytes] × N
//
// All multi-byte integers are BIG-ENDIAN.
//
// References:
//   http://shuffle-db.sourceforge.net/
//   https://web.archive.org/web/20120204023148/http://ipodlinux.org/ITunesSD

// MARK: - Track Entry

struct iTunesSDTrack {
    // Offset 0:  3 bytes — startPositionMS (big-endian uint24, usually 0)
    var startPositionMS: UInt32 = 0

    // Offset 3:  3 bytes — stopPositionMS (0 = play to end)
    var stopPositionMS: UInt32 = 0

    // Offset 6:  3 bytes — volume (0x0059 = 89 = 100%, range 0–200 represents 0–200%)
    var volume: UInt32 = 0x59

    // Offset 9:  1 byte  — fileType (0x01 = MP3, 0x02 = AAC/M4A, 0x04 = WAV)
    var fileType: UInt8 = 0x01

    // Offset 10: 1 byte  — unknown1 (0x200 in some docs; write 0x02)
    var unknown1: UInt8 = 0x02

    // Offset 11: 1 byte  — unknown2 (write 0x00)
    var unknown2: UInt8 = 0x00

    // Offset 12: 1 byte  — shuffleFlag (0x01 = include in shuffle, 0x00 = skip)
    var shuffleFlag: UInt8 = 0x01

    // Offset 13: 1 byte  — podcastFlag (0x00 = normal, 0x01 = podcast)
    var podcastFlag: UInt8 = 0x00

    // Offset 14: 1 byte  — bookmarkFlag (0x00 = no bookmark)
    var bookmarkFlag: UInt8 = 0x00

    // Offset 15: 1 byte  — unknown3 (write 0x00)
    var unknown3: UInt8 = 0x00

    // Offset 16–527: 256 UTF-16BE code units = 512 bytes — file path
    // Path is relative to iPod root, e.g. /iPod_Control/Music/f00/AAAA.mp3
    var filePath: String = ""

    // Offset 528–557: 30 bytes padding / reserved (write zeros)
}

// MARK: - Header

struct iTunesSDHeader {
    // Bytes 0–2:  3-byte big-endian track count
    var trackCount: UInt32

    // Bytes 3–4:  2 bytes — unknown, write 0x0100
    var unknown1: UInt16 = 0x0100

    // Bytes 5–17: 13 bytes — padding/unknown, write zeros
}

// MARK: - Database

struct iPodShuffleDatabase {
    var tracks: [iTunesSDTrack] = []

    // MARK: Parse from Data

    static func parse(from data: Data) throws -> iPodShuffleDatabase {
        guard data.count >= 16 else {
            throw iPodSyncError.invalidDatabase("File too small for header")
        }

        // Header: first 3 bytes = track count (big-endian uint24)
        let trackCount = UInt32(data[0]) << 16 | UInt32(data[1]) << 8 | UInt32(data[2])

        guard data.count >= 16 + Int(trackCount) * 558 else {
            throw iPodSyncError.invalidDatabase("File truncated — expected \(trackCount) tracks")
        }

        var tracks: [iTunesSDTrack] = []
        for i in 0..<Int(trackCount) {
            let offset = 16 + i * 558
            let entry = data.subdata(in: offset..<(offset + 558))
            let track = try parseTrackEntry(entry)
            tracks.append(track)
        }

        return iPodShuffleDatabase(tracks: tracks)
    }

    private static func parseTrackEntry(_ data: Data) throws -> iTunesSDTrack {
        guard data.count == 558 else {
            throw iPodSyncError.invalidDatabase("Track entry wrong size: \(data.count)")
        }

        var track = iTunesSDTrack()
        track.startPositionMS = UInt32(data[0]) << 16 | UInt32(data[1]) << 8 | UInt32(data[2])
        track.stopPositionMS  = UInt32(data[3]) << 16 | UInt32(data[4]) << 8 | UInt32(data[5])
        track.volume          = UInt32(data[6]) << 16 | UInt32(data[7]) << 8 | UInt32(data[8])
        track.fileType        = data[9]
        track.unknown1        = data[10]
        track.unknown2        = data[11]
        track.shuffleFlag     = data[12]
        track.podcastFlag     = data[13]
        track.bookmarkFlag    = data[14]
        track.unknown3        = data[15]

        // Path: 256 UTF-16BE code units starting at offset 29
        let pathData = data.subdata(in: 35..<558)
        track.filePath = String(data: pathData, encoding: .utf16LittleEndian)?
            .trimmingCharacters(in: .init(charactersIn: "\0")) ?? ""

        return track
    }

    // MARK: Serialise to Data

    func serialise() -> Data {
        var data = Data()

        let count = tracks.count
        data.append(UInt8((count >> 16) & 0xFF))
        data.append(UInt8((count >> 8)  & 0xFF))
        data.append(UInt8( count        & 0xFF))
        data.append(contentsOf: [0x01, 0x08])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x12])
        data.append(contentsOf: [UInt8](repeating: 0, count: 7))

        assert(data.count == 16, "Header must be 16 bytes, got \(data.count)")

        for track in tracks {
            data.append(contentsOf: serialiseTrack(track))
        }
        return data
    }

    private func serialiseTrack(_ track: iTunesSDTrack) -> [UInt8] {
        var entry = [UInt8](repeating: 0, count: 558)

        // Bytes 0–2: startPositionMS (uint24 BE)
        entry[0] = UInt8((track.startPositionMS >> 16) & 0xFF)
        entry[1] = UInt8((track.startPositionMS >> 8)  & 0xFF)
        entry[2] = UInt8( track.startPositionMS        & 0xFF)

        // Bytes 3–5: stopPositionMS (uint24 BE)
        entry[3] = UInt8((track.stopPositionMS >> 16) & 0xFF)
        entry[4] = UInt8((track.stopPositionMS >> 8)  & 0xFF)
        entry[5] = UInt8( track.stopPositionMS        & 0xFF)

        // Bytes 6–8: volume
        entry[6] = 0xa5
        entry[7] = 0x01
        entry[8] = 0x00

        // Bytes 9–25: zeros (already zero from initialisation)

        // Bytes 26–28: mystery bytes, exactly as iTunes writes them
        entry[31] = 0x01
        entry[32] = 0x00
        entry[33] = 0x02

        // Bytes 29–556: file path as UTF-16BE, zero padded
        let pathBytes = encodePathUTF16LE(track.filePath)
        for (i, byte) in pathBytes.enumerated() where i < 527 {
            entry[35 + i] = byte
        }

        entry[557] = 0x01

        return entry
    }

    private func encodePathUTF16LE(_ path: String) -> [UInt8] {
        var bytes = [UInt8]()
        for codeUnit in path.utf16 {
            bytes.append(UInt8(codeUnit & 0xFF))
            bytes.append(UInt8((codeUnit >> 8) & 0xFF))
        }
        while bytes.count < 523 { bytes.append(0) }
        return bytes
    }
}

// MARK: - File Type Detection

extension iPodShuffleDatabase {
    static func fileType(for url: URL) -> UInt8 {
        switch url.pathExtension.lowercased() {
        case "mp3":       return 0x01
        case "aac", "m4a", "m4b", "m4p": return 0x02
        case "wav":       return 0x04
        case "aa":        return 0x01   // Audible (treat as MP3 slot)
        default:          return 0x01
        }
    }
}

// MARK: - Errors

enum iPodSyncError: LocalizedError {
    case deviceNotFound
    case invalidDatabase(String)
    case writeFailure(String)
    case unsupportedFormat(String)
    case copyFailure(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:          return "iPod not found or not mounted."
        case .invalidDatabase(let m):  return "Database error: \(m)"
        case .writeFailure(let m):     return "Write failed: \(m)"
        case .unsupportedFormat(let m):return "Unsupported format: \(m)"
        case .copyFailure(let m):      return "Copy failed: \(m)"
        }
    }
}
