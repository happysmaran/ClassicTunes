import Foundation
import AVFoundation

// Errors surfaced while attempting to rewrite a track's embedded tags on disk.
enum SongMetadataWriteError: LocalizedError {
    case unsupportedFormat
    case exportSessionUnavailable
    case exportFailed(String)
    case malformedFile(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "This file format doesn't support in-place tag editing."
        case .exportSessionUnavailable:
            return "Could not prepare this file for editing."
        case .exportFailed(let message):
            return message
        case .malformedFile(let message):
            return message
        }
    }
}

// Rewrites a song's editable tags directly into its audio file container.
//
// Every format is handled by finding the container's tag/metadata region and swapping it
// out, leaving the encoded audio bytes completely untouched:
//   - m4a / mp4 / aac: re-muxed via `AVAssetExportSession`'s passthrough preset, which lets
//     AVFoundation itself relocate the `moov` atom without touching sample data.
//   - mp3: an ID3v2.3 tag is (re)written at the head of the file, replacing any existing one.
//   - wav: a RIFF `LIST`/`INFO` chunk is (re)written, replacing any existing one.
//   - flac: the `VORBIS_COMMENT` metadata block is (re)written, replacing any existing one.
enum SongMetadataWriter {

    // Reports whether `write(_:to:)` can persist tag edits into the file at this URL.
    static func canWriteToFile(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "aac", "mp3", "wav", "flac": return true
        default: return false
        }
    }

    // Dispatches to the format-appropriate tag writer for the song's file extension.
    //
    // - Parameters:
    //   - song: The edited metadata to persist.
    //   - url: The location of the audio file to rewrite in place.
    static func write(_ song: Song, to url: URL) async throws {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "aac":
            try await writeMPEG4(song, to: url)
        case "mp3":
            try writeID3(song, to: url)
        case "wav":
            try writeWAV(song, to: url)
        case "flac":
            try writeFLAC(song, to: url)
        default:
            throw SongMetadataWriteError.unsupportedFormat
        }
    }

    // MARK: - MPEG-4 family (m4a / mp4 / aac)

    // Re-muxes the audio track unchanged while swapping in the song's current tag values.
    private static func writeMPEG4(_ song: Song, to url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw SongMetadataWriteError.exportSessionUnavailable
        }
        export.metadata = mpeg4MetadataItems(for: song)

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try await export.export(to: tempURL, as: .m4a)
        } catch {
            throw SongMetadataWriteError.exportFailed(error.localizedDescription)
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    // Builds the iTunes-style MPEG-4 atoms matching what `Song.load(from:)` parses back on read.
    private static func mpeg4MetadataItems(for song: Song) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = [
            mpeg4StringItem(.iTunesMetadataSongName, song.title),
            mpeg4StringItem(.iTunesMetadataArtist, song.artist),
            mpeg4StringItem(.iTunesMetadataAlbum, song.album),
            mpeg4StringItem(.iTunesMetadataUserGenre, song.genre)
        ]
        if let year = song.year { items.append(mpeg4StringItem(.iTunesMetadataReleaseDate, year)) }
        if let composer = song.composer { items.append(mpeg4StringItem(.iTunesMetadataComposer, composer)) }
        if let comment = song.comment { items.append(mpeg4StringItem(.iTunesMetadataUserComment, comment)) }
        if let track = song.trackNumber { items.append(mpeg4NumberItem(.iTunesMetadataTrackNumber, track)) }
        if let disc = song.discNumber { items.append(mpeg4NumberItem(.iTunesMetadataDiscNumber, disc)) }
        return items
    }

    private static func mpeg4StringItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    private static func mpeg4NumberItem(_ identifier: AVMetadataIdentifier, _ value: Int) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = NSNumber(value: value)
        return item
    }

    // MARK: - MP3 (ID3v2.3)

    // Prepends a fresh ID3v2.3 tag, replacing any existing one. The audio frame data
    // after the old tag (or after byte 0, if there wasn't one) is copied verbatim.
    private static func writeID3(_ song: Song, to url: URL) throws {
        let original = try Data(contentsOf: url)

        var audioStart = 0
        if original.count >= 10,
           original[0] == 0x49, original[1] == 0x44, original[2] == 0x33 { // "ID3"
            let existingSize = syncsafeToInt(original.subdata(in: 6..<10))
            audioStart = 10 + existingSize
        }
        guard audioStart <= original.count else {
            throw SongMetadataWriteError.malformedFile("Malformed existing ID3 tag.")
        }
        let audioData = original.subdata(in: audioStart..<original.count)

        var frames = Data()
        frames.append(id3TextFrame("TIT2", song.title))
        frames.append(id3TextFrame("TPE1", song.artist))
        frames.append(id3TextFrame("TALB", song.album))
        frames.append(id3TextFrame("TCON", song.genre))
        if let year = song.year { frames.append(id3TextFrame("TYER", year)) }
        if let composer = song.composer { frames.append(id3TextFrame("TCOM", composer)) }
        if let comment = song.comment { frames.append(id3CommentFrame(comment)) }
        if let track = song.trackNumber { frames.append(id3TextFrame("TRCK", String(track))) }
        if let disc = song.discNumber { frames.append(id3TextFrame("TPOS", String(disc))) }

        var tag = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00]) // "ID3", v2.3.0, flags = 0
        tag.append(intToSyncsafe(UInt32(frames.count)))
        tag.append(frames)

        var rebuilt = Data()
        rebuilt.append(tag)
        rebuilt.append(audioData)
        try rebuilt.write(to: url, options: .atomic)
    }

    private static func id3TextFrame(_ id: String, _ value: String) -> Data {
        var payload = Data([0x01, 0xFF, 0xFE]) // encoding: UTF-16 with little-endian BOM
        payload.append(value.data(using: .utf16LittleEndian) ?? Data())
        return id3Frame(id, payload)
    }

    private static func id3CommentFrame(_ value: String) -> Data {
        var payload = Data([0x01]) // encoding: UTF-16
        payload.append(contentsOf: [0x65, 0x6E, 0x67]) // language: "eng"
        payload.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00]) // empty short description: BOM + null terminator
        payload.append(contentsOf: [0xFF, 0xFE]) // BOM for the actual text
        payload.append(value.data(using: .utf16LittleEndian) ?? Data())
        return id3Frame("COMM", payload)
    }

    private static func id3Frame(_ id: String, _ payload: Data) -> Data {
        var frame = Data(id.utf8)
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) })
        frame.append(contentsOf: [0x00, 0x00]) // flags
        frame.append(payload)
        return frame
    }

    // ID3v2 header sizes (and only header sizes — frame sizes in v2.3 are plain big-endian)
    // are "syncsafe": 4 bytes each holding 7 usable bits, high bit always zero.
    private static func syncsafeToInt(_ bytes: Data) -> Int {
        bytes.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
    }

    private static func intToSyncsafe(_ value: UInt32) -> Data {
        var v = value
        var bytes = [UInt8](repeating: 0, count: 4)
        for i in stride(from: 3, through: 0, by: -1) {
            bytes[i] = UInt8(v & 0x7F)
            v >>= 7
        }
        return Data(bytes)
    }

    // MARK: - WAV (RIFF LIST/INFO chunk)

    // Rebuilds the file's top-level RIFF chunks verbatim, dropping any existing LIST/INFO
    // chunk and appending a freshly built one. `fmt ` and `data` (the audio) are untouched.
    private static func writeWAV(_ song: Song, to url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 12,
              data.subdata(in: 0..<4).elementsEqual(Array("RIFF".utf8)),
              data.subdata(in: 8..<12).elementsEqual(Array("WAVE".utf8)) else {
            throw SongMetadataWriteError.malformedFile("Not a valid WAV file.")
        }

        var rebuilt = data.subdata(in: 0..<12)
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(data: data.subdata(in: offset..<offset + 4), encoding: .ascii) ?? ""
            let size = Int(readUInt32LE(data, at: offset + 4))
            let chunkEnd = offset + 8 + size + (size % 2)
            guard chunkEnd <= data.count else { break }

            let isExistingInfoList = id == "LIST" && size >= 4
                && (String(data: data.subdata(in: offset + 8..<offset + 12), encoding: .ascii) ?? "") == "INFO"

            if !isExistingInfoList {
                rebuilt.append(data.subdata(in: offset..<chunkEnd))
            }
            offset = chunkEnd
        }

        rebuilt.append(buildRIFFListInfoChunk(for: song))

        let riffSize = UInt32(rebuilt.count - 8)
        rebuilt.replaceSubrange(4..<8, with: writeUInt32LE(riffSize))

        try rebuilt.write(to: url, options: .atomic)
    }

    private static func buildRIFFListInfoChunk(for song: Song) -> Data {
        var info = Data("INFO".utf8)
        info.append(riffInfoSubchunk("INAM", song.title))
        info.append(riffInfoSubchunk("IART", song.artist))
        info.append(riffInfoSubchunk("IPRD", song.album))
        info.append(riffInfoSubchunk("IGNR", song.genre))
        if let year = song.year { info.append(riffInfoSubchunk("ICRD", year)) }
        if let comment = song.comment { info.append(riffInfoSubchunk("ICMT", comment)) }

        var chunk = Data("LIST".utf8)
        chunk.append(writeUInt32LE(UInt32(info.count)))
        chunk.append(info)
        if chunk.count % 2 != 0 { chunk.append(0) }
        return chunk
    }

    private static func riffInfoSubchunk(_ id: String, _ value: String) -> Data {
        var text = Data(value.utf8)
        text.append(0) // null terminator; included in the declared size
        let size = UInt32(text.count)
        if text.count % 2 != 0 { text.append(0) } // pad byte; not included in the declared size

        var chunk = Data(id.utf8)
        chunk.append(writeUInt32LE(size))
        chunk.append(text)
        return chunk
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func writeUInt32LE(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    // MARK: - FLAC (VORBIS_COMMENT metadata block)

    // Rebuilds the file's metadata block chain, dropping any existing VORBIS_COMMENT block
    // (type 4) and appending a freshly built one last. STREAMINFO and any other blocks
    // (e.g. PICTURE) are preserved in their original order; audio frames are untouched.
    private static func writeFLAC(_ song: Song, to url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 4, data.subdata(in: 0..<4).elementsEqual(Array("fLaC".utf8)) else {
            throw SongMetadataWriteError.malformedFile("Not a valid FLAC file.")
        }

        var keptBlocks: [Data] = []
        var offset = 4
        var isLast = false
        while !isLast && offset + 4 <= data.count {
            let headerByte = data[offset]
            isLast = (headerByte & 0x80) != 0
            let blockType = headerByte & 0x7F
            let length = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let blockStart = offset + 4
            let blockEnd = blockStart + length
            guard blockEnd <= data.count else { break }

            if blockType != 4 { // drop existing VORBIS_COMMENT; keep everything else (incl. STREAMINFO first)
                let payload = data.subdata(in: blockStart..<blockEnd)
                keptBlocks.append(flacBlockHeader(type: blockType, length: payload.count) + payload)
            }
            offset = blockEnd
        }
        let audioData = data.subdata(in: offset..<data.count)

        let commentPayload = buildVorbisCommentBlock(for: song)
        keptBlocks.append(flacBlockHeader(type: 4, length: commentPayload.count) + commentPayload)

        var rebuilt = Data("fLaC".utf8)
        for (index, var block) in keptBlocks.enumerated() {
            if index == keptBlocks.count - 1 {
                block[block.startIndex] |= 0x80
            } else {
                block[block.startIndex] &= 0x7F
            }
            rebuilt.append(block)
        }
        rebuilt.append(audioData)

        try rebuilt.write(to: url, options: .atomic)
    }

    private static func flacBlockHeader(type: UInt8, length: Int) -> Data {
        Data([
            type & 0x7F,
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF)
        ])
    }

    private static func buildVorbisCommentBlock(for song: Song) -> Data {
        var comments = [
            "TITLE=\(song.title)",
            "ARTIST=\(song.artist)",
            "ALBUM=\(song.album)",
            "GENRE=\(song.genre)"
        ]
        if let year = song.year { comments.append("DATE=\(year)") }
        if let composer = song.composer { comments.append("COMPOSER=\(composer)") }
        if let comment = song.comment { comments.append("COMMENT=\(comment)") }
        if let track = song.trackNumber { comments.append("TRACKNUMBER=\(track)") }
        if let disc = song.discNumber { comments.append("DISCNUMBER=\(disc)") }

        var data = Data()
        let vendorBytes = Array("ClassicTunes".utf8)
        data.append(writeUInt32LE(UInt32(vendorBytes.count)))
        data.append(contentsOf: vendorBytes)
        data.append(writeUInt32LE(UInt32(comments.count)))
        for comment in comments {
            let bytes = Array(comment.utf8)
            data.append(writeUInt32LE(UInt32(bytes.count)))
            data.append(contentsOf: bytes)
        }
        return data
    }
}
