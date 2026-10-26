import Foundation

// Tags read straight from a file's own metadata structures.
//
// AVFoundation exposes FLAC (Vorbis comments) and WAV (RIFF INFO) tags under key spaces that
// `Song.load` doesn't map, so those files used to load with the filename as the title and
// "Unknown Artist". Reading the structures directly is deterministic, case-insensitive for Vorbis
// field names, and also finds FLAC cover art.
nonisolated struct EmbeddedTags: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var year: String?
    var composer: String?
    var comment: String?
    var albumArtist: String?
    var grouping: String?
    var trackNumber: Int?
    var discNumber: Int?
    var bpm: Int?
    var compilation: Bool?
    var artworkData: Data?
}

nonisolated enum EmbeddedTagReader {

    // Largest single metadata block that will be read into memory. Real tags are far smaller;
    // this only guards against a corrupt length field.
    private static let maxBlockSize = 64 * 1024 * 1024

    // The tags in a FLAC or WAV file, or nil for other formats or files that can't be read.
    static func read(from url: URL) -> EmbeddedTags? {
        switch url.pathExtension.lowercased() {
        case "flac": return readFLAC(at: url)
        case "wav": return readWAV(at: url)
        default: return nil
        }
    }

    // MARK: - FLAC

    // Walks the metadata blocks at the head of the file, reading only VORBIS_COMMENT and PICTURE
    // blocks and skipping the rest (including the audio, which is never touched).
    static func readFLAC(at url: URL) -> EmbeddedTags? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let marker = try? handle.read(upToCount: 4), marker == Data("fLaC".utf8) else { return nil }

        var tags = EmbeddedTags()
        var artworkType = -1
        var isLast = false
        while !isLast {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])

            switch type {
            case 4, 6:
                guard length <= maxBlockSize,
                      let payload = try? handle.read(upToCount: length), payload.count == length else { return tags }
                if type == 4 {
                    applyVorbisComments(parseVorbisComments(payload), to: &tags)
                } else if let picture = parseFLACPicture(payload) {
                    // Prefer the front cover; otherwise keep the first picture found.
                    if tags.artworkData == nil || (picture.type == 3 && artworkType != 3) {
                        tags.artworkData = picture.data
                        artworkType = picture.type
                    }
                }
            default:
                guard skip(handle, by: length) else { return tags }
            }
        }
        return tags
    }

    // "NAME=value" pairs from a VORBIS_COMMENT payload, with names upper-cased. Anything that doesn't
    // parse cleanly just ends the list; reading never fails loudly.
    static func parseVorbisComments(_ payload: Data) -> [(name: String, value: String)] {
        var offset = 0
        func readLength() -> Int? {
            guard offset + 4 <= payload.count else { return nil }
            defer { offset += 4 }
            let start = payload.startIndex + offset
            return Int(payload[start]) | Int(payload[start + 1]) << 8 | Int(payload[start + 2]) << 16 | Int(payload[start + 3]) << 24
        }

        guard let vendorLength = readLength(), offset + vendorLength <= payload.count else { return [] }
        offset += vendorLength
        guard let count = readLength() else { return [] }

        var comments: [(name: String, value: String)] = []
        for _ in 0..<count {
            guard let length = readLength(), offset + length <= payload.count else { break }
            let bytes = payload.subdata(in: payload.startIndex + offset..<payload.startIndex + offset + length)
            offset += length
            let text = String(decoding: bytes, as: UTF8.self)
            guard let separator = text.firstIndex(of: "=") else { continue }
            comments.append((text[..<separator].uppercased(), String(text[text.index(after: separator)...])))
        }
        return comments
    }

    // Fills `tags` from Vorbis comments. The first non-blank value of each field wins, so a file
    // with several ARTIST entries shows the first.
    private static func applyVorbisComments(_ comments: [(name: String, value: String)], to tags: inout EmbeddedTags) {
        for (name, rawValue) in comments {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch name {
            case "TITLE": tags.title = tags.title ?? value
            case "ARTIST": tags.artist = tags.artist ?? value
            case "ALBUM": tags.album = tags.album ?? value
            case "GENRE": tags.genre = tags.genre ?? value
            case "DATE", "YEAR": tags.year = tags.year ?? value
            case "COMPOSER": tags.composer = tags.composer ?? value
            case "COMMENT", "DESCRIPTION": tags.comment = tags.comment ?? value
            case "ALBUMARTIST", "ALBUM ARTIST": tags.albumArtist = tags.albumArtist ?? value
            case "GROUPING", "CONTENTGROUP": tags.grouping = tags.grouping ?? value
            case "TRACKNUMBER", "TRACK": tags.trackNumber = tags.trackNumber ?? leadingInt(value)
            case "DISCNUMBER", "DISC": tags.discNumber = tags.discNumber ?? leadingInt(value)
            case "BPM", "TEMPO": tags.bpm = tags.bpm ?? leadingInt(value)
            case "COMPILATION": tags.compilation = tags.compilation ?? (value == "1" || value.lowercased() == "true")
            default: break
            }
        }
    }

    // A METADATA_BLOCK_PICTURE payload: picture type, MIME type, description, dimensions, then the
    // image bytes (all lengths big-endian).
    private static func parseFLACPicture(_ payload: Data) -> (type: Int, data: Data)? {
        var offset = 0
        func readBE() -> Int? {
            guard offset + 4 <= payload.count else { return nil }
            defer { offset += 4 }
            let start = payload.startIndex + offset
            return Int(payload[start]) << 24 | Int(payload[start + 1]) << 16 | Int(payload[start + 2]) << 8 | Int(payload[start + 3])
        }

        guard let type = readBE(),
              let mimeLength = readBE(), offset + mimeLength <= payload.count else { return nil }
        offset += mimeLength
        guard let descriptionLength = readBE(), offset + descriptionLength <= payload.count else { return nil }
        offset += descriptionLength
        // width, height, colour depth, indexed colours
        for _ in 0..<4 { guard readBE() != nil else { return nil } }
        guard let dataLength = readBE(), dataLength > 0, offset + dataLength <= payload.count else { return nil }
        let start = payload.startIndex + offset
        return (type, payload.subdata(in: start..<start + dataLength))
    }

    // MARK: - WAV

    // Scans the top-level RIFF chunks, reading only the LIST/INFO chunk (the audio chunk is skipped).
    static func readWAV(at url: URL) -> EmbeddedTags? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12,
              header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8),
              let fileSize = try? handle.seekToEnd() else { return nil }

        var tags = EmbeddedTags()
        var offset: UInt64 = 12
        while offset + 8 <= fileSize {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let chunkHeader = try? handle.read(upToCount: 8), chunkHeader.count == 8 else { break }
            let id = String(decoding: chunkHeader.prefix(4), as: UTF8.self)
            let size = Int(chunkHeader[4]) | Int(chunkHeader[5]) << 8 | Int(chunkHeader[6]) << 16 | Int(chunkHeader[7]) << 24

            if id == "LIST", size >= 4, size <= maxBlockSize,
               let body = try? handle.read(upToCount: size), body.count == size,
               body.prefix(4) == Data("INFO".utf8) {
                applyInfoEntries(parseInfoEntries(Data(body.dropFirst(4))), to: &tags)
            }
            offset += 8 + UInt64(size) + UInt64(size % 2)
        }
        return tags
    }

    private static func parseInfoEntries(_ body: Data) -> [(id: String, value: String)] {
        var entries: [(id: String, value: String)] = []
        var offset = 0
        while offset + 8 <= body.count {
            let start = body.startIndex + offset
            let id = String(decoding: body[start..<start + 4], as: UTF8.self)
            let size = Int(body[start + 4]) | Int(body[start + 5]) << 8 | Int(body[start + 6]) << 16 | Int(body[start + 7]) << 24
            let end = offset + 8 + size
            guard end <= body.count else { break }
            var text = body.subdata(in: start + 8..<start + 8 + size)
            while text.last == 0 { text.removeLast() }
            // INFO text is nominally ASCII; modern tools write UTF-8, older ones Windows-1252.
            let value = String(data: text, encoding: .utf8) ?? String(data: text, encoding: .isoLatin1) ?? ""
            entries.append((id, value))
            offset = end + (size % 2)
        }
        return entries
    }

    private static func applyInfoEntries(_ entries: [(id: String, value: String)], to tags: inout EmbeddedTags) {
        for (id, rawValue) in entries {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch id {
            case "INAM": tags.title = tags.title ?? value
            case "IART": tags.artist = tags.artist ?? value
            case "IPRD": tags.album = tags.album ?? value
            case "IGNR": tags.genre = tags.genre ?? value
            case "ICRD": tags.year = tags.year ?? value
            case "ICMT": tags.comment = tags.comment ?? value
            case "ITRK": tags.trackNumber = tags.trackNumber ?? leadingInt(value)
            default: break
            }
        }
    }

    // MARK: - Helpers

    // The integer at the start of "3" or "3/12".
    private static func leadingInt(_ text: String) -> Int? {
        let head = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        return Int(head.trimmingCharacters(in: .whitespaces))
    }

    // Moves the read position forward without reading the bytes.
    private static func skip(_ handle: FileHandle, by length: Int) -> Bool {
        guard let position = try? handle.offset() else { return false }
        return (try? handle.seek(toOffset: position + UInt64(length))) != nil
    }
}
