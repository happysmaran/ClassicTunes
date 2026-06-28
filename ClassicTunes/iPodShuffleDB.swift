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

// Represents a single 558-byte track record in the iTunesSD database.
// Field offsets/sizes follow the on-disk layout documented above each property.
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
    // Path is relative to iPod root, e.g. /iPod_Control/Music/F00/AAAA.mp3
    var filePath: String = ""

    // File name. Nothing more to it.
    // (Not part of the on-disk format — populated later in-memory for UI display,
    // e.g. from AVAsset metadata lookups, see iPodDeviceView.)
    var displayName: String = ""

    // Offset 528–557: 30 bytes padding / reserved (write zeros)
}

// MARK: - Header

// Represents the 16/18-byte header that precedes the track entries in the file.
struct iTunesSDHeader {
    // Bytes 0–2:  3-byte big-endian track count
    var trackCount: UInt32

    // Bytes 3–4:  2 bytes — unknown, write 0x0100
    var unknown1: UInt16 = 0x0100

    // Bytes 5–17: 13 bytes — padding/unknown, write zeros
}

// MARK: - Database

// In-memory representation of the whole iTunesSD file: a header (track count)
// followed by an array of fixed-size track entries. Provides parse() to read
// raw Data from disk into Swift structs, and serialise() to go back to Data
// for writing to the device.
struct iPodShuffleDatabase {
    var tracks: [iTunesSDTrack] = []

    // MARK: Parse from Data

    // Reads a raw iTunesSD file (header + N track entries) into an
    // iPodShuffleDatabase. Throws if the file is too small or truncated
    // relative to the track count encoded in the header.
    static func parse(from data: Data) throws -> iPodShuffleDatabase {
        guard data.count >= 16 else {
            throw iPodSyncError.invalidDatabase("File too small for header")
        }

        // Header: first 3 bytes = track count (big-endian uint24)
        let trackCount = UInt32(data[0]) << 16 | UInt32(data[1]) << 8 | UInt32(data[2])

        // Each track entry is a fixed 558 bytes; the header occupies the
        // first 16 bytes, so the file must be at least 16 + trackCount*558 long.
        guard data.count >= 16 + Int(trackCount) * 558 else {
            throw iPodSyncError.invalidDatabase("File truncated — expected \(trackCount) tracks")
        }

        // Walk the file in 558-byte chunks (one per track) starting after the header.
        var tracks: [iTunesSDTrack] = []
        for i in 0..<Int(trackCount) {
            let offset = 16 + i * 558
            let entry = data.subdata(in: offset..<(offset + 558))
            let track = try parseTrackEntry(entry)
            tracks.append(track)
        }

        return iPodShuffleDatabase(tracks: tracks)
    }

    // Decodes a single 558-byte track entry blob into an iTunesSDTrack.
    private static func parseTrackEntry(_ data: Data) throws -> iTunesSDTrack {
        guard data.count == 558 else {
            throw iPodSyncError.invalidDatabase("Track entry wrong size: \(data.count)")
        }

        let start = data.startIndex

        var track = iTunesSDTrack()
        // Read the three big-endian uint24 fields (start/stop position, volume).
        track.startPositionMS = UInt32(data[0]) << 16 | UInt32(data[1]) << 8 | UInt32(data[2])
        track.stopPositionMS  = UInt32(data[3]) << 16 | UInt32(data[4]) << 8 | UInt32(data[5])
        track.volume          = UInt32(data[6]) << 16 | UInt32(data[7]) << 8 | UInt32(data[8])
        // Single-byte flag fields.
        track.fileType        = data[9]
        track.unknown1        = data[10]
        track.unknown2        = data[11]
        track.shuffleFlag     = data[12]
        track.podcastFlag     = data[13]
        track.bookmarkFlag    = data[14]
        track.unknown3        = data[15]

        // File path block: UTF-16 string starting at byte offset 35 (relative
        // to this entry) through the end of the 558-byte entry.
        let pathData = data.subdata(in: (start + 35)..<(start + 558))
        //print("Parsing path block bytes: \(pathData as NSData)")

        // Decode the path bytes as little-endian UTF-16 and strip any
        // trailing NUL padding / whitespace left over from the fixed-size field.
        if let decodedString = String(data: pathData, encoding: .utf16LittleEndian) {
            track.filePath = decodedString.replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            track.filePath = ""
        }

        return track
    }

    // MARK: Serialise to Data

    // Builds the full on-disk byte representation: header followed by each
    // track's serialised 558-byte entry, ready to be written to the device.
    func serialise() -> Data {
        var data = Data()

        // --- Header (16 bytes) ---
        let count = tracks.count
        // Track count as big-endian uint24.
        data.append(UInt8((count >> 16) & 0xFF))
        data.append(UInt8((count >> 8)  & 0xFF))
        data.append(UInt8( count        & 0xFF))
        // Fixed header bytes used by iTunes.
        data.append(contentsOf: [0x01, 0x08])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x12])
        data.append(contentsOf: [UInt8](repeating: 0, count: 7))

        assert(data.count == 16, "Header must be 16 bytes, got \(data.count)")

        // --- Track entries ---
        for track in tracks {
            data.append(contentsOf: serialiseTrack(track))
        }
        return data
    }

    // Encodes a single iTunesSDTrack back into its fixed 558-byte on-disk form.
    private func serialiseTrack(_ track: iTunesSDTrack) -> [UInt8] {
        // Start from an all-zero buffer; this naturally fills in the
        // reserved/padding regions described in the struct's field comments.
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

    // Encodes a Swift String as little-endian UTF-16 bytes, zero-padded out
    // to 523 bytes so the resulting field always has a consistent length.
    private func encodePathUTF16LE(_ path: String) -> [UInt8] {
        var bytes = [UInt8]()
        for codeUnit in path.utf16 {
            // Each UTF-16 code unit becomes two bytes, low byte first (little-endian).
            bytes.append(UInt8(codeUnit & 0xFF))
            bytes.append(UInt8((codeUnit >> 8) & 0xFF))
        }
        // Pad remaining space with zero bytes.
        while bytes.count < 523 { bytes.append(0) }
        return bytes
    }
}

// MARK: - File Type Detection

// Maps a file's extension to the iTunesSD fileType byte value.
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

// Error cases surfaced throughout the sync pipeline (device discovery,
// database parsing/writing, file copying, format support).
enum iPodSyncError: LocalizedError {
    case deviceNotFound
    case invalidDatabase(String)
    case writeFailure(String)
    case unsupportedFormat(String)
    case copyFailure(String)

    // Human-readable description shown to the user / logged for each error case.
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
