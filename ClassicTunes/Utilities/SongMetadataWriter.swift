import Foundation
import AVFoundation

// Errors surfaced while attempting to rewrite a track's embedded tags on disk.
enum SongMetadataWriteError: LocalizedError {
    case unsupportedFormat
    case exportSessionUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "This file format doesn't support in-place tag editing."
        case .exportSessionUnavailable:
            return "Could not prepare this file for editing."
        case .exportFailed(let message):
            return message
        }
    }
}

// Rewrites a song's editable tags directly into its audio file container.
//
// Only MPEG-4 family containers (.m4a, .mp4, .aac) support rewriting tags without
// re-encoding the audio, via `AVAssetExportSession`'s passthrough preset. For literally
// any other format, another method will have to be used. Hmmmmmm.
enum SongMetadataWriter {

    // Reports whether `write(_:to:)` can persist tag edits into the file at this URL.
    static func canWriteToFile(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "aac": return true
        default: return false
        }
    }

    // Re-muxes the audio track unchanged while swapping in the song's current tag values.
    //
    // - Parameters:
    //   - song: The edited metadata to persist.
    //   - url: The location of the audio file to rewrite in place.
    static func write(_ song: Song, to url: URL) async throws {
        guard canWriteToFile(url) else { throw SongMetadataWriteError.unsupportedFormat }

        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw SongMetadataWriteError.exportSessionUnavailable
        }
        export.metadata = metadataItems(for: song)

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
    private static func metadataItems(for song: Song) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = [
            stringItem(.iTunesMetadataSongName, song.title),
            stringItem(.iTunesMetadataArtist, song.artist),
            stringItem(.iTunesMetadataAlbum, song.album),
            stringItem(.iTunesMetadataUserGenre, song.genre)
        ]
        if let year = song.year { items.append(stringItem(.iTunesMetadataReleaseDate, year)) }
        if let composer = song.composer { items.append(stringItem(.iTunesMetadataComposer, composer)) }
        if let comment = song.comment { items.append(stringItem(.iTunesMetadataUserComment, comment)) }
        if let track = song.trackNumber { items.append(numberItem(.iTunesMetadataTrackNumber, track)) }
        if let disc = song.discNumber { items.append(numberItem(.iTunesMetadataDiscNumber, disc)) }
        return items
    }

    private static func stringItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    private static func numberItem(_ identifier: AVMetadataIdentifier, _ value: Int) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = NSNumber(value: value)
        return item
    }
}
