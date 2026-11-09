import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

// Audio inspection and database access shared by the iTunesDB (Mini, Nano, Classic) code paths.
// Syncing itself lives in SyncEngine and ClassicLibrary.
enum ClassicBackend {
    // MARK: Locations

    static func databaseURL(base: URL) -> URL {
        base.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
    }

    static func loadDocument(base: URL) throws -> ITunesDBDocument {
        let url = databaseURL(base: base)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ITunesDBError.noDatabase }
        return try ITunesDBDocument(data: Data(contentsOf: url))
    }

    // MARK: Audio inspection

    static func durationMS(of song: Song) async -> UInt32 {
        if let seconds = song.duration, seconds > 0 { return UInt32(clamping: Int(seconds * 1000)) }
        let asset = AVURLAsset(url: song.url)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        return seconds.isFinite && seconds > 0 ? UInt32(clamping: Int(seconds * 1000)) : 0
    }

    // Lyrics are read by the iPod from the audio file itself (ID3 USLT or the MP4 lyrics atom);
    // the database only carries a presence flag, so the file is checked rather than any Song field.
    static func hasEmbeddedLyrics(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        for format in [AVMetadataFormat.id3Metadata, .iTunesMetadata] {
            guard let items = try? await asset.loadMetadata(for: format) else { continue }
            for item in items where item.identifier == .id3MetadataUnsynchronizedLyric
                || item.identifier == .iTunesMetadataLyrics {
                if let text = try? await item.load(.stringValue), !text.isEmpty { return true }
                if let value = try? await item.load(.value), value != nil { return true }
            }
        }
        return false
    }

    // Returns nil for formats the iPod cannot decode (FLAC, Ogg, Opus, ...). FLAC is converted to
    // AAC while syncing (ConversionPipeline); the others are not supported.
    static func encoding(for url: URL) async -> ClassicAudioEncoding? {
        switch url.pathExtension.lowercased() {
        case "mp3": return .mp3
        case "wav", "wave": return .wav
        case "aif", "aiff": return .aiff
        case "m4a", "m4b", "mp4":
            // AAC and Apple Lossless share the .m4a container but need different filetype flags.
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .audio).first,
               let descriptions = try? await track.load(.formatDescriptions),
               let first = descriptions.first,
               CMFormatDescriptionGetMediaSubType(first) == kAudioFormatAppleLossless {
                return .alac
            }
            return .aac
        default:
            return nil
        }
    }

    static func audioProperties(for url: URL) async -> (bitrateKbps: UInt32, sampleRateHz: UInt32) {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return (0, 44100) }
        let rate = (try? await track.load(.estimatedDataRate)) ?? 0
        var hz: UInt32 = 44100
        if let description = (try? await track.load(.formatDescriptions))?.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
           asbd.mSampleRate > 0 {
            hz = UInt32(clamping: Int(asbd.mSampleRate))
        }
        return (rate.isFinite && rate > 0 ? UInt32(rate / 1000) : 0, hz)
    }
}
