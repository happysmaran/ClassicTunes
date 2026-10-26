import Foundation
import AVFoundation
import CoreMedia
import ImageIO

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

// A tag the editor can change. The writer only touches the fields that differ between the song as
// it was loaded and the song as edited.
enum SongTagField: CaseIterable {
    case title, artist, album, genre, year, trackNumber, discNumber
    case composer, comment, albumArtist, grouping, compilation, bpm, artwork
}

// Rewrites a song's editable tags directly into its audio file container.
//
// Every format is handled by finding the container's tag/metadata region and swapping it
// out, leaving the encoded audio bytes completely untouched:
//   - m4a / mp4 / aac: re-muxed via `AVAssetExportSession`'s passthrough preset, which lets
//     AVFoundation itself relocate the `moov` atom without touching sample data.
//   - mp3: an ID3v2 tag is rewritten at the head of the file, keeping the existing tag's version.
//   - wav: a RIFF `LIST`/`INFO` chunk is rewritten.
//   - flac: the `VORBIS_COMMENT` metadata block is rewritten.
//
// Only the fields that changed are replaced. Everything else already in the file (lyrics, ratings,
// ReplayGain, gapless data, extra pictures, custom fields...) is carried over untouched, including
// fields this app doesn't read or display. That also means a field the app failed to read from a
// file is never overwritten with a placeholder just because the song was saved.
enum SongMetadataWriter {

    // Reports whether `write` can persist tag edits into the file at this URL.
    static func canWriteToFile(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "aac", "mp3", "wav", "flac": return true
        default: return false
        }
    }

    // The fields whose values differ between `original` and `song`. With no `original`, every
    // field counts as changed.
    static func changedFields(from original: Song?, to song: Song) -> Set<SongTagField> {
        guard let original else { return Set(SongTagField.allCases) }
        var changed = Set<SongTagField>()
        if song.title != original.title { changed.insert(.title) }
        if song.artist != original.artist { changed.insert(.artist) }
        if song.album != original.album { changed.insert(.album) }
        if song.genre != original.genre { changed.insert(.genre) }
        if song.year != original.year { changed.insert(.year) }
        if song.trackNumber != original.trackNumber { changed.insert(.trackNumber) }
        if song.discNumber != original.discNumber { changed.insert(.discNumber) }
        if song.composer != original.composer { changed.insert(.composer) }
        if song.comment != original.comment { changed.insert(.comment) }
        if song.albumArtist != original.albumArtist { changed.insert(.albumArtist) }
        if song.grouping != original.grouping { changed.insert(.grouping) }
        if song.compilation != original.compilation { changed.insert(.compilation) }
        if song.bpm != original.bpm { changed.insert(.bpm) }
        if song.artworkKey != original.artworkKey { changed.insert(.artwork) }
        return changed
    }

    // Dispatches to the format-appropriate tag writer for the song's file extension.
    //
    // - Parameters:
    //   - song: The edited metadata to persist.
    //   - original: The song as it was before editing. Only fields that differ from it are written.
    //     Pass `nil` to write every field.
    //   - url: The location of the audio file to rewrite in place.
    static func write(_ song: Song, replacing original: Song? = nil, to url: URL) async throws {
        let changed = changedFields(from: original, to: song)
        guard !changed.isEmpty else { return }

        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "aac":
            try await writeMPEG4(song, changed: changed, to: url)
        case "mp3":
            try writeID3(song, changed: changed, to: url)
        case "wav":
            try writeWAV(song, changed: changed, to: url)
        case "flac":
            try writeFLAC(song, changed: changed, to: url)
        default:
            throw SongMetadataWriteError.unsupportedFormat
        }
    }

    // MARK: - Field values

    // A text value, or nil if it is blank (blank means "remove the tag").
    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    // The tag value for a text-like field, or nil when the field should be absent from the file.
    private static func textValue(of field: SongTagField, in song: Song) -> String? {
        switch field {
        case .title: return nonBlank(song.title)
        case .artist: return nonBlank(song.artist)
        case .album: return nonBlank(song.album)
        case .genre: return nonBlank(song.genre)
        case .year: return nonBlank(song.year)
        case .composer: return nonBlank(song.composer)
        case .comment: return nonBlank(song.comment)
        case .albumArtist: return nonBlank(song.albumArtist)
        case .grouping: return nonBlank(song.grouping)
        case .trackNumber: return song.trackNumber.map(String.init)
        case .discNumber: return song.discNumber.map(String.init)
        case .bpm: return song.bpm.map(String.init)
        case .compilation: return song.compilation ? "1" : nil
        case .artwork: return nil
        }
    }

    // MARK: - MPEG-4 family (m4a / mp4 / aac)

    // Re-muxes the audio track unchanged. The file's existing metadata is read back and passed to
    // the export along with the edited fields, so tags the app doesn't manage survive.
    private static func writeMPEG4(_ song: Song, changed: Set<SongTagField>, to url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw SongMetadataWriteError.exportSessionUnavailable
        }
        export.metadata = try await mergedMPEG4Metadata(for: song, changed: changed, existingIn: asset)

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

    // Key spaces holding the iTunes-style atoms (`itsk`) and freeform atoms (`itlk`) of an MP4 file.
    private static let carriedMPEG4KeySpaces: Set<String> = ["itsk", "itlk"]

    // The file's existing iTunes-style items, minus the ones for changed fields, plus the new values.
    private static func mergedMPEG4Metadata(
        for song: Song,
        changed: Set<SongTagField>,
        existingIn asset: AVURLAsset
    ) async throws -> [AVMetadataItem] {
        let replaced = Set(changed.flatMap { mpeg4Identifiers(for: $0) })

        var items: [AVMetadataItem] = []
        for item in try await asset.load(.metadata) {
            guard let keySpace = item.keySpace?.rawValue, carriedMPEG4KeySpaces.contains(keySpace) else { continue }
            if let identifier = item.identifier?.rawValue, replaced.contains(identifier) { continue }

            // Items read from a file load their value lazily; make sure it is present on the copy.
            let value = try await item.load(.value)
            guard let copy = item.mutableCopy() as? AVMutableMetadataItem else { continue }
            copy.value = value
            copy.dataType = item.dataType
            items.append(copy)
        }

        for field in SongTagField.allCases where changed.contains(field) {
            items.append(contentsOf: mpeg4Items(for: field, in: song))
        }
        // Note: the export treats an empty list as "keep the source's metadata", so clearing the very
        // last tag in a file that has no other iTunes-style items can't be expressed. Files normally
        // carry at least encoder items (such as gapless playback data), which keeps the list non-empty.
        return items
    }

    // The raw identifiers an MP4 file may store this field under (including legacy alternates).
    private static func mpeg4Identifiers(for field: SongTagField) -> [String] {
        switch field {
        case .title: return [AVMetadataIdentifier.iTunesMetadataSongName.rawValue]
        case .artist: return [AVMetadataIdentifier.iTunesMetadataArtist.rawValue]
        case .album: return [AVMetadataIdentifier.iTunesMetadataAlbum.rawValue]
        case .genre: return [AVMetadataIdentifier.iTunesMetadataUserGenre.rawValue, AVMetadataIdentifier.iTunesMetadataPredefinedGenre.rawValue]
        case .year: return [AVMetadataIdentifier.iTunesMetadataReleaseDate.rawValue]
        case .composer: return [AVMetadataIdentifier.iTunesMetadataComposer.rawValue]
        case .comment: return [AVMetadataIdentifier.iTunesMetadataUserComment.rawValue]
        case .trackNumber: return [AVMetadataIdentifier.iTunesMetadataTrackNumber.rawValue]
        case .discNumber: return [AVMetadataIdentifier.iTunesMetadataDiscNumber.rawValue]
        case .albumArtist: return [AVMetadataIdentifier.iTunesMetadataAlbumArtist.rawValue]
        // ©grp is what Apple's Music app writes. (AVFoundation's own grouping identifier is `grup`,
        // which other apps don't recognise, so it is only listed to be replaced.)
        case .grouping: return ["itsk/%A9grp", AVMetadataIdentifier.iTunesMetadataGrouping.rawValue]
        case .compilation: return [AVMetadataIdentifier.iTunesMetadataDiscCompilation.rawValue]
        case .bpm: return [AVMetadataIdentifier.iTunesMetadataBeatsPerMin.rawValue]
        case .artwork: return [AVMetadataIdentifier.iTunesMetadataCoverArt.rawValue]
        }
    }

    // The new MPEG-4 atoms for one changed field (none when the field is being cleared).
    private static func mpeg4Items(for field: SongTagField, in song: Song) -> [AVMetadataItem] {
        guard let identifier = mpeg4Identifiers(for: field).first.map({ AVMetadataIdentifier(rawValue: $0) }) else { return [] }
        switch field {
        case .trackNumber:
            return song.trackNumber.map { [mpeg4PairItem(identifier, $0, byteCount: 8)] } ?? []
        case .discNumber:
            return song.discNumber.map { [mpeg4PairItem(identifier, $0, byteCount: 6)] } ?? []
        case .bpm:
            return song.bpm.map { [mpeg4NumberItem(identifier, $0)] } ?? []
        case .compilation:
            return song.compilation ? [mpeg4NumberItem(identifier, 1)] : []
        case .artwork:
            guard let data = song.artworkData else { return [] }
            return [mpeg4DataItem(identifier, data)]
        default:
            guard let text = textValue(of: field, in: song) else { return [] }
            return [mpeg4StringItem(identifier, text)]
        }
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

    // Track and disc numbers are stored the way Apple's apps store them: a binary record of
    // (reserved, number, total, [reserved]), not a plain integer. Other taggers read them that way,
    // and read a plain integer as 0. The total isn't known here, so it is left as 0 ("unspecified").
    private static func mpeg4PairItem(_ identifier: AVMetadataIdentifier, _ number: Int, byteCount: Int) -> AVMetadataItem {
        let value = UInt16(clamping: number)
        var bytes: [UInt8] = [0, 0, UInt8(value >> 8), UInt8(value & 0xFF), 0, 0]
        if byteCount > 6 { bytes.append(contentsOf: [UInt8](repeating: 0, count: byteCount - 6)) }
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = Data(bytes) as NSData
        item.dataType = kCMMetadataBaseDataType_RawData as String
        return item
    }

    private static func mpeg4DataItem(_ identifier: AVMetadataIdentifier, _ value: Data) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSData
        item.dataType = imageMIMEType(for: value) == "image/png" ? kCMMetadataBaseDataType_PNG as String : kCMMetadataBaseDataType_JPEG as String
        return item
    }

    // MARK: - Shared artwork helpers

    // Sniffs the image container format from its leading bytes; falls back to JPEG.
    private static func imageMIMEType(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        return "image/jpeg"
    }

    private static func imagePixelDimensions(for data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (0, 0)
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (width, height)
    }

    // MARK: - MP3 (ID3v2)

    // One frame of an existing ID3v2 tag, kept exactly as it was stored.
    struct ID3Frame {
        let id: String
        // The whole frame: 10-byte header followed by the payload.
        let raw: Data
        var payload: Data { Data(raw.dropFirst(10)) }
    }

    // An existing ID3v2 tag at the start of a file.
    struct ID3Tag {
        let majorVersion: UInt8
        let frames: [ID3Frame]
        // Offset of the first byte after the tag (including padding and any footer).
        let audioStart: Int
    }

    // Reads the ID3v2 tag at the head of the file, or returns nil if there isn't one. Throws for tags
    // that can't be rewritten without losing data, so nothing is changed in that case.
    static func readID3Tag(from input: FileHandle) throws -> ID3Tag? {
        try input.seek(toOffset: 0)
        guard let header = try input.read(upToCount: 10), header.count == 10,
              header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else { return nil } // "ID3"

        let major = header[3]
        let flags = header[5]
        guard major == 3 || major == 4 else {
            throw SongMetadataWriteError.malformedFile("This file uses an ID3v2.\(major) tag, which can't be edited without losing other tag data. No changes were made.")
        }
        guard flags & 0x80 == 0 else {
            throw SongMetadataWriteError.malformedFile("This file's ID3 tag uses unsynchronisation, which can't be edited safely. No changes were made.")
        }

        let tagSize = syncsafeToInt(header.subdata(in: 6..<10))
        let hasExtendedHeader = flags & 0x40 != 0
        let hasFooter = major == 4 && flags & 0x10 != 0
        var body = try input.read(upToCount: tagSize) ?? Data()
        guard body.count == tagSize else {
            throw SongMetadataWriteError.malformedFile("This file's ID3 tag is truncated. No changes were made.")
        }

        if hasExtendedHeader {
            guard body.count >= 4 else {
                throw SongMetadataWriteError.malformedFile("This file's ID3 tag is malformed. No changes were made.")
            }
            let sizeField = body.subdata(in: 0..<4)
            let skip = major == 4 ? syncsafeToInt(sizeField) : 4 + Int(readUInt32BE(sizeField, at: 0))
            guard skip <= body.count else {
                throw SongMetadataWriteError.malformedFile("This file's ID3 tag is malformed. No changes were made.")
            }
            body = Data(body.dropFirst(skip))
        }

        let frames = try parseID3Frames(body, majorVersion: major)
        return ID3Tag(majorVersion: major, frames: frames, audioStart: 10 + tagSize + (hasFooter ? 10 : 0))
    }

    private static func parseID3Frames(_ body: Data, majorVersion: UInt8) throws -> [ID3Frame] {
        var frames: [ID3Frame] = []
        var offset = 0
        while offset + 10 <= body.count {
            // A zero byte where a frame ID should start means the rest of the tag is padding.
            if body[offset] == 0 { break }

            let idBytes = body.subdata(in: offset..<offset + 4)
            guard idBytes.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }) else {
                throw SongMetadataWriteError.malformedFile("This file's ID3 tag couldn't be read safely. No changes were made.")
            }
            let sizeBytes = body.subdata(in: offset + 4..<offset + 8)
            let size = majorVersion == 4 ? syncsafeToInt(sizeBytes) : Int(readUInt32BE(sizeBytes, at: 0))
            let end = offset + 10 + size
            guard end <= body.count else {
                throw SongMetadataWriteError.malformedFile("This file's ID3 tag couldn't be read safely. No changes were made.")
            }
            frames.append(ID3Frame(id: String(decoding: idBytes, as: UTF8.self), raw: body.subdata(in: offset..<end)))
            offset = end
        }
        return frames
    }

    // Rewrites the tag at the head of the file. Frames for fields that didn't change are copied over
    // byte-for-byte, as is every frame the app doesn't manage, and the audio is streamed across
    // unchanged into a temporary file that then replaces the original.
    private static func writeID3(_ song: Song, changed: Set<SongTagField>, to url: URL) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }

        let existing = try readID3Tag(from: input)
        let version = existing?.majorVersion ?? 3
        let audioStart = existing?.audioStart ?? 0

        var frames: [Data] = (existing?.frames ?? [])
            .filter { !id3FrameIsReplaced($0, changed: changed) }
            .map(\.raw)
        for field in SongTagField.allCases where changed.contains(field) {
            if let frame = id3Frame(for: field, in: song, version: version) { frames.append(frame) }
        }
        let framesData = frames.reduce(into: Data()) { $0.append($1) }
        guard framesData.count < 1 << 28 else {
            throw SongMetadataWriteError.malformedFile("The tag data is too large to write.")
        }

        var tag = Data([0x49, 0x44, 0x33, version, 0x00, 0x00]) // "ID3", version, revision 0, flags 0
        tag.append(intToSyncsafe(UInt32(framesData.count)))
        tag.append(framesData)

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw SongMetadataWriteError.exportFailed("Could not create a temporary file next to the song.")
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let output = try FileHandle(forWritingTo: tempURL)
        do {
            try output.write(contentsOf: tag)
            try input.seek(toOffset: UInt64(audioStart))
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.close()
        } catch {
            try? output.close()
            throw error
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    // Whether an existing frame holds a value for one of the changed fields (and is therefore
    // superseded by the new value, or removed if the field was cleared).
    static func id3FrameIsReplaced(_ frame: ID3Frame, changed: Set<SongTagField>) -> Bool {
        switch frame.id {
        case "TIT2": return changed.contains(.title)
        case "TPE1": return changed.contains(.artist)
        case "TALB": return changed.contains(.album)
        case "TCON": return changed.contains(.genre)
        case "TYER", "TDRC": return changed.contains(.year)
        case "TCOM": return changed.contains(.composer)
        case "TRCK": return changed.contains(.trackNumber)
        case "TPOS": return changed.contains(.discNumber)
        case "TPE2": return changed.contains(.albumArtist)
        case "TIT1": return changed.contains(.grouping)
        case "TCMP": return changed.contains(.compilation)
        case "TBPM": return changed.contains(.bpm)
        case "COMM":
            // Only the user's comment (no description). Other COMM frames hold things like iTunes'
            // Sound Check data, which must survive.
            return changed.contains(.comment) && id3CommentHasEmptyDescription(frame.payload)
        case "APIC":
            // Only the front cover (and "other") pictures; back covers, booklets etc. stay.
            guard changed.contains(.artwork), let type = id3PictureType(frame.payload) else { return false }
            return type == 0x03 || type == 0x00
        default:
            return false
        }
    }

    // The picture type byte of an APIC payload: encoding, null-terminated MIME type, then the type.
    private static func id3PictureType(_ payload: Data) -> UInt8? {
        var index = 1
        while index < payload.count, payload[index] != 0 { index += 1 }
        index += 1
        return index < payload.count ? payload[index] : nil
    }

    // Whether a COMM frame's short description is empty. Layout: encoding, 3-byte language, then the
    // description, terminated by one null byte (ISO-8859-1 / UTF-8) or two (UTF-16, optionally BOM-first).
    private static func id3CommentHasEmptyDescription(_ payload: Data) -> Bool {
        guard payload.count >= 5 else { return false }
        let encoding = payload[0]
        switch encoding {
        case 0, 3:
            return payload[4] == 0
        case 1, 2:
            guard payload.count >= 6 else { return false }
            let bom = (payload[4] == 0xFF && payload[5] == 0xFE) || (payload[4] == 0xFE && payload[5] == 0xFF)
            if bom {
                return payload.count >= 8 && payload[6] == 0 && payload[7] == 0
            }
            return payload[4] == 0 && payload[5] == 0
        default:
            return false
        }
    }

    // The ID3 frame for one changed field, or nil when the field is being cleared.
    private static func id3Frame(for field: SongTagField, in song: Song, version: UInt8) -> Data? {
        switch field {
        case .title: return textValue(of: field, in: song).map { id3TextFrame("TIT2", $0, version: version) }
        case .artist: return textValue(of: field, in: song).map { id3TextFrame("TPE1", $0, version: version) }
        case .album: return textValue(of: field, in: song).map { id3TextFrame("TALB", $0, version: version) }
        case .genre: return textValue(of: field, in: song).map { id3TextFrame("TCON", $0, version: version) }
        case .year: return textValue(of: field, in: song).map { id3TextFrame(version == 4 ? "TDRC" : "TYER", $0, version: version) }
        case .composer: return textValue(of: field, in: song).map { id3TextFrame("TCOM", $0, version: version) }
        case .comment: return textValue(of: field, in: song).map { id3CommentFrame($0, version: version) }
        case .trackNumber: return textValue(of: field, in: song).map { id3TextFrame("TRCK", $0, version: version) }
        case .discNumber: return textValue(of: field, in: song).map { id3TextFrame("TPOS", $0, version: version) }
        case .albumArtist: return textValue(of: field, in: song).map { id3TextFrame("TPE2", $0, version: version) }
        case .grouping: return textValue(of: field, in: song).map { id3TextFrame("TIT1", $0, version: version) }
        case .compilation: return textValue(of: field, in: song).map { id3TextFrame("TCMP", $0, version: version) }
        case .bpm: return textValue(of: field, in: song).map { id3TextFrame("TBPM", $0, version: version) }
        case .artwork: return song.artworkData.map { id3PictureFrame($0, version: version) }
        }
    }

    private static func id3TextFrame(_ id: String, _ value: String, version: UInt8) -> Data {
        var payload = Data([0x01, 0xFF, 0xFE]) // encoding: UTF-16 with little-endian BOM
        payload.append(value.data(using: .utf16LittleEndian) ?? Data())
        return id3Frame(id, payload, version: version)
    }

    private static func id3CommentFrame(_ value: String, version: UInt8) -> Data {
        var payload = Data([0x01]) // encoding: UTF-16
        payload.append(contentsOf: [0x65, 0x6E, 0x67]) // language: "eng"
        payload.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00]) // empty short description: BOM + null terminator
        payload.append(contentsOf: [0xFF, 0xFE]) // BOM for the actual text
        payload.append(value.data(using: .utf16LittleEndian) ?? Data())
        return id3Frame("COMM", payload, version: version)
    }

    // Picture type 0x03 ("Cover (front)") with Latin-1 encoded, empty-description payload.
    private static func id3PictureFrame(_ data: Data, version: UInt8) -> Data {
        var payload = Data([0x00]) // encoding: ISO-8859-1
        payload.append((imageMIMEType(for: data)).data(using: .isoLatin1) ?? Data())
        payload.append(0x00) // MIME type null terminator
        payload.append(0x03) // picture type: front cover
        payload.append(0x00) // empty description + its null terminator
        payload.append(data)
        return id3Frame("APIC", payload, version: version)
    }

    // Frame sizes are plain big-endian in ID3v2.3 and syncsafe in ID3v2.4.
    private static func id3Frame(_ id: String, _ payload: Data, version: UInt8) -> Data {
        var frame = Data(id.utf8)
        if version == 4 {
            frame.append(intToSyncsafe(UInt32(payload.count)))
        } else {
            frame.append(writeUInt32BE(UInt32(payload.count)))
        }
        frame.append(contentsOf: [0x00, 0x00]) // flags
        frame.append(payload)
        return frame
    }

    // ID3v2 header sizes (and v2.4 frame sizes) are "syncsafe": 4 bytes each holding 7 usable bits,
    // high bit always zero. Frame sizes in v2.3 are plain big-endian.
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

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return (UInt32(data[start]) << 24) | (UInt32(data[start + 1]) << 16)
            | (UInt32(data[start + 2]) << 8) | UInt32(data[start + 3])
    }

    // MARK: - WAV (RIFF LIST/INFO chunk)

    // The INFO subchunk IDs used for each field (WAV has no equivalent for the others).
    private static func riffInfoID(for field: SongTagField) -> String? {
        switch field {
        case .title: return "INAM"
        case .artist: return "IART"
        case .album: return "IPRD"
        case .genre: return "IGNR"
        case .year: return "ICRD"
        case .comment: return "ICMT"
        case .trackNumber: return "ITRK"
        default: return nil
        }
    }

    // Rebuilds the file's top-level RIFF chunks verbatim, dropping any existing LIST/INFO chunk and
    // appending a freshly built one. The INFO entries for fields that didn't change (and any the app
    // doesn't manage, like software or copyright) are carried into the new chunk. `fmt ` and `data`
    // (the audio) are untouched.
    private static func writeWAV(_ song: Song, changed: Set<SongTagField>, to url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 12,
              data.subdata(in: 0..<4).elementsEqual(Array("RIFF".utf8)),
              data.subdata(in: 8..<12).elementsEqual(Array("WAVE".utf8)) else {
            throw SongMetadataWriteError.malformedFile("Not a valid WAV file.")
        }

        var rebuilt = data.subdata(in: 0..<12)
        var infoEntries: [(id: String, payload: Data)] = []
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(data: data.subdata(in: offset..<offset + 4), encoding: .ascii) ?? ""
            let size = Int(readUInt32LE(data, at: offset + 4))
            let chunkEnd = offset + 8 + size + (size % 2)
            guard chunkEnd <= data.count else { break }

            let isExistingInfoList = id == "LIST" && size >= 4
                && (String(data: data.subdata(in: offset + 8..<offset + 12), encoding: .ascii) ?? "") == "INFO"

            if isExistingInfoList {
                infoEntries.append(contentsOf: parseRIFFInfoEntries(data.subdata(in: offset + 12..<offset + 8 + size)))
            } else {
                rebuilt.append(data.subdata(in: offset..<chunkEnd))
            }
            offset = chunkEnd
        }

        let replacedIDs = Set(changed.compactMap { riffInfoID(for: $0) })
        var entries = infoEntries.filter { !replacedIDs.contains($0.id) }
        for field in SongTagField.allCases where changed.contains(field) {
            if let id = riffInfoID(for: field), let value = textValue(of: field, in: song) {
                entries.append((id: id, payload: Data(value.utf8)))
            }
        }
        if !entries.isEmpty {
            rebuilt.append(buildRIFFListInfoChunk(entries))
        }

        let riffSize = UInt32(rebuilt.count - 8)
        rebuilt.replaceSubrange(4..<8, with: writeUInt32LE(riffSize))

        try rebuilt.write(to: url, options: .atomic)
    }

    // The (id, text bytes) pairs inside an INFO list's body (the bytes after the "INFO" marker).
    private static func parseRIFFInfoEntries(_ body: Data) -> [(id: String, payload: Data)] {
        var entries: [(id: String, payload: Data)] = []
        var offset = 0
        while offset + 8 <= body.count {
            let id = String(data: body.subdata(in: offset..<offset + 4), encoding: .ascii) ?? ""
            let size = Int(readUInt32LE(body, at: offset + 4))
            let end = offset + 8 + size
            guard end <= body.count else { break }
            var payload = body.subdata(in: offset + 8..<end)
            if payload.last == 0 { payload.removeLast() } // the stored null terminator is re-added on write
            entries.append((id: id, payload: payload))
            offset = end + (size % 2)
        }
        return entries
    }

    private static func buildRIFFListInfoChunk(_ entries: [(id: String, payload: Data)]) -> Data {
        var info = Data("INFO".utf8)
        for entry in entries {
            info.append(riffInfoSubchunk(entry.id, entry.payload))
        }

        var chunk = Data("LIST".utf8)
        chunk.append(writeUInt32LE(UInt32(info.count)))
        chunk.append(info)
        if chunk.count % 2 != 0 { chunk.append(0) }
        return chunk
    }

    private static func riffInfoSubchunk(_ id: String, _ value: Data) -> Data {
        var text = value
        text.append(0) // null terminator; included in the declared size
        let size = UInt32(text.count)
        if text.count % 2 != 0 { text.append(0) } // pad byte; not included in the declared size

        var chunk = Data(id.utf8)
        chunk.append(writeUInt32LE(size))
        chunk.append(text)
        return chunk
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start])
            | (UInt32(data[start + 1]) << 8)
            | (UInt32(data[start + 2]) << 16)
            | (UInt32(data[start + 3]) << 24)
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

    // The Vorbis comment field names used for each field.
    private static func vorbisNames(for field: SongTagField) -> [String] {
        switch field {
        case .title: return ["TITLE"]
        case .artist: return ["ARTIST"]
        case .album: return ["ALBUM"]
        case .genre: return ["GENRE"]
        case .year: return ["DATE", "YEAR"]
        case .composer: return ["COMPOSER"]
        case .comment: return ["COMMENT"]
        case .trackNumber: return ["TRACKNUMBER"]
        case .discNumber: return ["DISCNUMBER"]
        case .albumArtist: return ["ALBUMARTIST"]
        case .grouping: return ["GROUPING"]
        case .compilation: return ["COMPILATION"]
        case .bpm: return ["BPM"]
        case .artwork: return []
        }
    }

    // Rebuilds the file's metadata block chain. The existing VORBIS_COMMENT block is read and rewritten
    // with only the changed fields replaced (every other comment, and the vendor string, is kept), and
    // PICTURE blocks are kept unless the artwork changed, in which case only front-cover pictures are
    // replaced. STREAMINFO and every other block keep their original order; audio frames are untouched.
    private static func writeFLAC(_ song: Song, changed: Set<SongTagField>, to url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 4, data.subdata(in: 0..<4).elementsEqual(Array("fLaC".utf8)) else {
            throw SongMetadataWriteError.malformedFile("Not a valid FLAC file.")
        }

        var keptBlocks: [Data] = []
        var vendor = "ClassicTunes"
        var comments: [String] = []
        var offset = 4
        var isLast = false
        while !isLast && offset + 4 <= data.count {
            let headerByte = data[offset]
            isLast = (headerByte & 0x80) != 0
            let blockType = headerByte & 0x7F
            let length = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let blockStart = offset + 4
            let blockEnd = blockStart + length
            guard blockEnd <= data.count else {
                throw SongMetadataWriteError.malformedFile("This file's metadata couldn't be read safely. No changes were made.")
            }
            let payload = data.subdata(in: blockStart..<blockEnd)

            switch blockType {
            case 4: // VORBIS_COMMENT: read now, rewritten below
                let parsed = try parseVorbisComment(payload)
                vendor = parsed.vendor
                comments = parsed.comments
            case 6: // PICTURE: front covers (and "other") are replaced only when the artwork changed
                let pictureType = payload.count >= 4 ? Int(readUInt32BE(payload, at: 0)) : -1
                let isReplaced = changed.contains(.artwork) && (pictureType == 3 || pictureType == 0)
                if !isReplaced {
                    keptBlocks.append(flacBlockHeader(type: blockType, length: payload.count) + payload)
                }
            default:
                keptBlocks.append(flacBlockHeader(type: blockType, length: payload.count) + payload)
            }
            offset = blockEnd
        }
        let audioData = data.subdata(in: offset..<data.count)

        // Drop the comments for changed fields, then add their new values.
        let replacedNames = Set(changed.flatMap { vorbisNames(for: $0) })
        comments.removeAll { comment in
            guard let separator = comment.firstIndex(of: "=") else { return false }
            return replacedNames.contains(comment[..<separator].uppercased())
        }
        for field in SongTagField.allCases where changed.contains(field) {
            if let name = vorbisNames(for: field).first, let value = textValue(of: field, in: song) {
                comments.append("\(name)=\(value)")
            }
        }

        let commentPayload = buildVorbisCommentBlock(vendor: vendor, comments: comments)
        keptBlocks.append(flacBlockHeader(type: 4, length: commentPayload.count) + commentPayload)
        if changed.contains(.artwork), let artworkData = song.artworkData {
            let picturePayload = buildFLACPictureBlock(for: artworkData)
            keptBlocks.append(flacBlockHeader(type: 6, length: picturePayload.count) + picturePayload)
        }

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

    // Splits a VORBIS_COMMENT payload into its vendor string and "NAME=value" comments.
    static func parseVorbisComment(_ payload: Data) throws -> (vendor: String, comments: [String]) {
        func malformed() -> SongMetadataWriteError {
            .malformedFile("This file's Vorbis comments couldn't be read safely. No changes were made.")
        }
        var offset = 0
        func readLength() throws -> Int {
            guard offset + 4 <= payload.count else { throw malformed() }
            defer { offset += 4 }
            return Int(readUInt32LE(payload, at: offset))
        }

        let vendorLength = try readLength()
        guard offset + vendorLength <= payload.count else { throw malformed() }
        let vendor = String(decoding: payload.subdata(in: offset..<offset + vendorLength), as: UTF8.self)
        offset += vendorLength

        let count = try readLength()
        var comments: [String] = []
        for _ in 0..<count {
            let length = try readLength()
            guard offset + length <= payload.count else { throw malformed() }
            comments.append(String(decoding: payload.subdata(in: offset..<offset + length), as: UTF8.self))
            offset += length
        }
        return (vendor, comments)
    }

    // Builds a METADATA_BLOCK_PICTURE payload (type 0x03 "Cover (front)") per the FLAC spec,
    // all fields big-endian.
    private static func buildFLACPictureBlock(for artworkData: Data) -> Data {
        let mimeBytes = Array(imageMIMEType(for: artworkData).utf8)
        let (width, height) = imagePixelDimensions(for: artworkData)

        var block = Data()
        block.append(writeUInt32BE(3)) // picture type: front cover
        block.append(writeUInt32BE(UInt32(mimeBytes.count)))
        block.append(contentsOf: mimeBytes)
        block.append(writeUInt32BE(0)) // description length (none)
        block.append(writeUInt32BE(UInt32(width)))
        block.append(writeUInt32BE(UInt32(height)))
        block.append(writeUInt32BE(0)) // color depth: unknown
        block.append(writeUInt32BE(0)) // colors used: non-indexed
        block.append(writeUInt32BE(UInt32(artworkData.count)))
        block.append(artworkData)
        return block
    }

    private static func writeUInt32BE(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private static func flacBlockHeader(type: UInt8, length: Int) -> Data {
        Data([
            type & 0x7F,
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF)
        ])
    }

    private static func buildVorbisCommentBlock(vendor: String, comments: [String]) -> Data {
        var data = Data()
        let vendorBytes = Array(vendor.utf8)
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
