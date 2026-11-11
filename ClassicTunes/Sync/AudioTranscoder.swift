import AVFoundation

// Re-encodes a song to AAC at a lower bitrate so a large library fits on a small iPod. It exists
// because the iPod plays the file it is given and has no way to shrink it afterwards.
nonisolated enum AudioTranscoder {
    // Writes a temporary .m4a the caller must delete. Title, artist, album and cover art are
    // carried over; the iPod's own database is built from the Mac library, so nothing else in the
    // file has to survive.
    // `lyrics` are written into the file because the iPod shows only what is inside it.
    static func convertToAAC(_ original: URL, bitrateKbps: Int, lyrics: String? = nil) async throws -> URL {
        // Ogg has no AVFoundation reader, so its decoded PCM is what gets encoded.
        var source = original
        var decoded: URL?
        if OggAudio.isOgg(original) {
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("ClassicTunes-\(UUID().uuidString).wav")
            try OggAudio.decodeToWAV(original, to: wav)
            decoded = wav
            source = wav
        }
        defer { if let decoded { try? FileManager.default.removeItem(at: decoded) } }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscodeError("\(source.lastPathComponent) has no audio to convert")
        }
        var metadata = (try? await asset.load(.commonMetadata)) ?? []
        if let lyrics, !lyrics.isEmpty {
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataLyrics
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = lyrics as NSString
            metadata.append(item)
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassicTunes-\(UUID().uuidString).m4a")
        // 44.1 kHz stereo is what every iPod decodes; a 48 kHz or surround source is resampled.
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
        ]
        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: bitrateKbps * 1000,
        ]

        let job = try Job(asset: asset, track: track, output: output, pcm: pcm, aac: aac, metadata: metadata)
        do {
            try await job.run()
            try rewriteForIPod(output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    // AVAssetWriter puts the audio first and stores its size as a 64-bit "extended" box length. iPod
    // firmware parses the layout iTunes writes (ftyp, moov, mdat, all 32-bit sizes), and a converted
    // file in any other layout is skipped during playback. The audio itself is not touched; only the
    // boxes are reordered and the chunk offsets in the index shifted to match.
    static func rewriteForIPod(_ url: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        func u32(_ o: Int) -> Int { Int(bytes[o]) << 24 | Int(bytes[o + 1]) << 16 | Int(bytes[o + 2]) << 8 | Int(bytes[o + 3]) }
        func u64(_ o: Int) -> Int { (u32(o) << 32) | u32(o + 4) }
        func put32(_ o: Int, _ value: Int) {
            for i in 0..<4 { bytes[o + i] = UInt8((value >> (24 - 8 * i)) & 0xFF) }
        }
        func put64(_ o: Int, _ value: Int) {
            for i in 0..<8 { bytes[o + i] = UInt8((value >> (56 - 8 * i)) & 0xFF) }
        }
        func boxes(_ start: Int, _ end: Int) -> [(offset: Int, size: Int, type: String, header: Int)] {
            var result: [(offset: Int, size: Int, type: String, header: Int)] = []
            var o = start
            while o + 8 <= end {
                var size = u32(o)
                var header = 8
                let type = String(decoding: bytes[(o + 4)..<(o + 8)], as: UTF8.self)
                if size == 1 {
                    guard o + 16 <= end else { break }
                    size = u64(o + 8)
                    header = 16
                } else if size == 0 {
                    size = end - o
                }
                guard size >= header, o + size <= end else { break }
                result.append((o, size, type, header))
                o += size
            }
            return result
        }

        let top = boxes(0, bytes.count)
        guard let ftyp = top.first(where: { $0.type == "ftyp" }),
              let moov = top.first(where: { $0.type == "moov" }),
              let mdat = top.first(where: { $0.type == "mdat" }) else {
            throw TranscodeError("The converted file has an unexpected layout.")
        }
        let payloadLength = mdat.size - mdat.header
        guard 8 + payloadLength <= Int(UInt32.max) else { throw TranscodeError("The converted file is too large.") }
        // Audio moves to just after ftyp + moov, behind a plain 8-byte header.
        let delta = (ftyp.size + moov.size + 8) - (mdat.offset + mdat.header)

        func shiftOffsets(_ start: Int, _ end: Int) throws {
            for box in boxes(start, end) {
                let body = box.offset + box.header
                switch box.type {
                case "trak", "mdia", "minf", "stbl":
                    try shiftOffsets(body, box.offset + box.size)
                case "stco":
                    for i in 0..<u32(body + 4) {
                        let position = body + 8 + 4 * i
                        let moved = u32(position) + delta
                        guard moved >= 0, moved <= Int(UInt32.max) else { throw TranscodeError("The converted file's index is out of range.") }
                        put32(position, moved)
                    }
                case "co64":
                    for i in 0..<u32(body + 4) {
                        let position = body + 8 + 8 * i
                        put64(position, u64(position) + delta)
                    }
                default:
                    break
                }
            }
        }
        try shiftOffsets(moov.offset + moov.header, moov.offset + moov.size)

        var output = Data()
        output.append(contentsOf: bytes[ftyp.offset..<(ftyp.offset + ftyp.size)])
        output.append(contentsOf: bytes[moov.offset..<(moov.offset + moov.size)])
        var header = [UInt8](repeating: 0, count: 8)
        let total = 8 + payloadLength
        for i in 0..<4 { header[i] = UInt8((total >> (24 - 8 * i)) & 0xFF) }
        header.replaceSubrange(4..<8, with: Array("mdat".utf8))
        output.append(contentsOf: header)
        output.append(contentsOf: bytes[(mdat.offset + mdat.header)..<(mdat.offset + mdat.size)])
        try output.write(to: url, options: .atomic)
    }

    // Its own type rather than SyncFailure because it is thrown from the converter's background queue.
    nonisolated struct TranscodeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // Reader and writer are driven from one dispatch queue, which is why they are not touched
    // from anywhere else.
    private nonisolated final class Job: @unchecked Sendable {
        let reader: AVAssetReader
        let readerOutput: AVAssetReaderTrackOutput
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let queue = DispatchQueue(label: "ClassicTunes.transcode")

        init(asset: AVURLAsset, track: AVAssetTrack, output: URL, pcm: [String: Any], aac: [String: Any], metadata: [AVMetadataItem]) throws {
            reader = try AVAssetReader(asset: asset)
            readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
            reader.add(readerOutput)
            writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
            writer.metadata = metadata
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            writer.add(input)
        }

        func run() async throws {
            guard reader.startReading(), writer.startWriting() else {
                throw reader.error ?? writer.error ?? TranscodeError("The audio converter could not start.")
            }
            writer.startSession(atSourceTime: .zero)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while input.isReadyForMoreMediaData {
                        guard let buffer = readerOutput.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            if reader.status == .failed {
                                writer.cancelWriting()
                                continuation.resume(throwing: reader.error ?? TranscodeError("Reading the source audio failed."))
                                return
                            }
                            writer.finishWriting { [self] in
                                if writer.status == .completed {
                                    continuation.resume()
                                } else {
                                    continuation.resume(throwing: writer.error ?? TranscodeError("Writing the converted audio failed."))
                                }
                            }
                            return
                        }
                        if !input.append(buffer) {
                            reader.cancelReading()
                            writer.cancelWriting()
                            continuation.resume(throwing: writer.error ?? TranscodeError("Writing the converted audio failed."))
                            return
                        }
                    }
                }
            }
        }
    }
}
