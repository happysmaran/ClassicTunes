import AVFoundation

// Re-encodes a song to AAC at a lower bitrate so a large library fits on a small iPod. It exists
// because the iPod plays the file it is given and has no way to shrink it afterwards.
nonisolated enum AudioTranscoder {
    // Writes a temporary .m4a the caller must delete. Title, artist, album and cover art are
    // carried over; the iPod's own database is built from the Mac library, so nothing else in the
    // file has to survive.
    static func convertToAAC(_ source: URL, bitrateKbps: Int) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscodeError("\(source.lastPathComponent) has no audio to convert")
        }
        let metadata = (try? await asset.load(.commonMetadata)) ?? []

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
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
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
