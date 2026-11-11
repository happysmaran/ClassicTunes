import Foundation
import CryptoKit

// AVFoundation cannot open Ogg Vorbis or Opus, so these files are read and decoded by the C
// decoder in Ogg/. The library reads their tags and duration from it; playback and syncing work
// from a decoded WAV copy.
nonisolated enum OggAudio {
    static let extensions: Set<String> = ["ogg", "oga", "opus"]

    static func isOgg(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    struct Info {
        var channels: Int
        var sampleRate: Int
        var duration: TimeInterval
        var bitrateKbps: Double
        var tags: EmbeddedTags
    }

    struct DecodeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func scan(_ url: URL) -> Info? {
        var info = CTOggInfo()
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
        defer { errorBuffer.deallocate() }
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return 1 }
            return ct_ogg_scan(path, &info, errorBuffer, 256)
        }
        guard status == 0 else { return nil }
        defer { ct_ogg_free(info.comments) }

        var tags = EmbeddedTags()
        if let pointer = info.comments, info.commentsLength > 0 {
            let comments = EmbeddedTagReader.parseVorbisComments(Data(bytes: pointer, count: info.commentsLength))
            EmbeddedTagReader.applyVorbisComments(comments, to: &tags)
            // Cover art is stored as a base64 FLAC picture block inside a comment.
            var artworkType = -1
            for (name, value) in comments where name == "METADATA_BLOCK_PICTURE" {
                guard let block = Data(base64Encoded: value), let picture = EmbeddedTagReader.parseFLACPicture(block) else { continue }
                if tags.artworkData == nil || (picture.type == 3 && artworkType != 3) {
                    tags.artworkData = picture.data
                    artworkType = picture.type
                }
            }
        }
        return Info(channels: Int(info.channels), sampleRate: Int(info.sampleRate),
                    duration: info.duration, bitrateKbps: info.bitrateKbps, tags: tags)
    }

    static func decodeToWAV(_ source: URL, to destination: URL) throws {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
        defer { errorBuffer.deallocate() }
        errorBuffer.pointee = 0
        let status = source.withUnsafeFileSystemRepresentation { input -> Int32 in
            destination.withUnsafeFileSystemRepresentation { output -> Int32 in
                guard let input, let output else { return 1 }
                return ct_ogg_decode_to_wav(input, output, errorBuffer, 256)
            }
        }
        guard status == 0 else {
            let reason = String(cString: errorBuffer)
            throw DecodeError(reason.isEmpty ? "\(source.lastPathComponent) could not be decoded." : reason)
        }
    }
}

// AVPlayer cannot read Ogg either, so a song is decoded once and the WAV is kept for later plays.
// The cache is bounded because a decoded song is roughly ten times the size of its source.
nonisolated enum OggPlaybackCache {
    private static let limitBytes: Int64 = 2 * 1024 * 1024 * 1024

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClassicTunes/OggPlayback", isDirectory: true)
    }

    private static func location(for source: URL) -> URL {
        let values = try? source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(source.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).wav")
    }

    static func cachedURL(for source: URL) -> URL? {
        let url = location(for: source)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func prepare(_ source: URL) async throws -> URL {
        if let cached = cachedURL(for: source) { return cached }
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let destination = location(for: source)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let partial = destination.appendingPathExtension("part")
            try? fm.removeItem(at: partial)
            try OggAudio.decodeToWAV(source, to: partial)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: partial, to: destination)
            prune(keeping: destination)
            return destination
        }.value
    }

    // Oldest decoded songs go first; the one just made is never removed.
    private static func prune(keeping keep: URL) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (url: URL, date: Date, size: Int64)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, Int64(values.fileSize ?? 0))
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > limitBytes && entry.url != keep {
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
