import AVFoundation

// Lyrics live in different places per format (a sidecar .lrc, Vorbis LYRICS comments in FLAC,
// ID3 USLT in MP3, the ©lyr atom in M4A). Sync needs one answer so the text can be written into
// the copy the iPod reads, since the iPod only looks inside the audio file itself.
nonisolated enum LyricsReader {
    static func lyrics(for url: URL) async -> String? {
        let sidecar = url.deletingPathExtension().appendingPathExtension("lrc")
        if let text = clean(try? String(contentsOf: sidecar, encoding: .utf8)) { return text }
        if let text = clean(EmbeddedTagReader.read(from: url)?.lyrics) { return text }

        let asset = AVURLAsset(url: url)
        if let text = clean(try? await asset.load(.lyrics)) { return text }
        for format in [AVMetadataFormat.id3Metadata, .iTunesMetadata] {
            guard let items = try? await asset.loadMetadata(for: format) else { continue }
            for item in items where item.identifier == .id3MetadataUnsynchronizedLyric
                || item.identifier == .iTunesMetadataLyrics {
                if let text = clean(try? await item.load(.stringValue)) { return text }
            }
        }
        return nil
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
