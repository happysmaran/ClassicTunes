import Foundation
import AVFoundation
@testable import ClassicTunes

// Shared helpers for tests that need real audio files.

enum AudioFixtureFormat: String {
    case m4a, wav, flac

    var settings: [String: Any] {
        var settings: [String: Any] = [AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1]
        switch self {
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVLinearPCMBitDepthKey] = 16
        }
        return settings
    }
}

// A fresh, empty directory under the test host's temporary directory.
func makeScratchDirectory(_ label: String = "Scratch") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

// Writes `seconds` of audio to `url`, creating parent folders. Silent by default so tests that
// play it back make no noise.
@discardableResult
func writeAudioFixture(_ format: AudioFixtureFormat, to url: URL, seconds: Double = 1, silent: Bool = true) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let frames = AVAudioFrameCount(44100 * seconds)
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: frames)!
        buffer.frameLength = frames
        if !silent {
            let samples = buffer.floatChannelData![0]
            for index in 0..<Int(frames) { samples[index] = 0.1 * sinf(Float(index) / 20) }
        }
        try file.write(from: buffer)
    } // the file is finalized when it goes out of scope
    return url
}

// Re-muxes an m4a with the given tags, standing in for a file tagged by another program.
func retag(_ source: URL, with items: [AVMetadataItem]) async throws {
    let temp = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
    defer { try? FileManager.default.removeItem(at: temp) }
    guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
        throw SongMetadataWriteError.exportSessionUnavailable
    }
    export.metadata = items
    try await export.export(to: temp, as: .m4a)
    _ = try FileManager.default.replaceItemAt(source, withItemAt: temp)
}

func stringTag(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = value as NSString
    item.extendedLanguageTag = "und"
    return item
}

func pngTag(_ data: Data) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = .iTunesMetadataCoverArt
    item.value = data as NSData
    item.dataType = kCMMetadataBaseDataType_PNG as String
    return item
}

// An MP4 atom holding raw bytes, the way Apple's apps store track/disc records and predefined genres.
func rawTag(_ identifier: AVMetadataIdentifier, _ bytes: [UInt8]) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = Data(bytes) as NSData
    item.dataType = kCMMetadataBaseDataType_RawData as String
    return item
}

// An MP4 atom holding a plain integer (how older versions of this app stored track and disc numbers).
func numberTag(_ identifier: AVMetadataIdentifier, _ value: Int) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = NSNumber(value: value)
    return item
}
