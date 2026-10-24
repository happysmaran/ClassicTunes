import Foundation
import AVFoundation
import Combine

// The loudness index behind "Stable Volume". Like iTunes' Sound Check, every song in the
// library is measured once when the option is turned on; the results are saved to disk and
// only songs that are new or changed since the last run get measured again.
// AVPlayer can only attenuate (volume is capped at 1.0), so songs louder than the
// target are turned down and quieter songs are left alone.
@MainActor
final class StableVolumeIndex: ObservableObject {
    static let shared = StableVolumeIndex()

    struct Entry: Codable {
        // Average (RMS) level in dBFS, or nil if the file couldn't be analyzed.
        var level: Float?
        // File fingerprint used to detect that a song has changed since it was measured.
        var modified: Double
        var size: Int
    }

    // Progress of the index build, shown in Settings.
    @Published private(set) var isAnalyzing = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var entries: [String: Entry] = [:]

    // Average (RMS) level, in dBFS, that loud songs are brought down to.
    private static let targetLevel: Float = -16
    // Never turn a song down by more than this many dB.
    private static let maxAttenuation: Float = 12
    // Length of the section of each song that gets measured.
    private nonisolated static let sampleSeconds: Double = 30
    // Songs measured at the same time while building the index.
    private static let concurrency = 2

    private var libraryURLs: [URL] = []
    private var task: Task<Void, Never>?

    private init() {
        entries = Self.loadFromDisk()
    }

    // MARK: - Summary for Settings

    // How many analyzed songs get turned down at all.
    var adjustedCount: Int {
        entries.values.filter { Self.attenuation(for: $0.level) > 0.5 }.count
    }

    // MARK: - Index maintenance

    // Called whenever the library's set of files changes (and when the option is toggled).
    func sync(with urls: [URL]) {
        libraryURLs = urls
        resync()
    }

    // Re-checks the last known library against the saved index, measuring only what's missing or changed.
    func resync() {
        guard UserDefaults.standard.bool(forKey: "isStableVolumeEnabled") else {
            task?.cancel()
            task = nil
            isAnalyzing = false
            return
        }
        // The library is briefly empty while it loads; don't treat that as "everything was removed".
        guard !libraryURLs.isEmpty else { return }

        let paths = Set(libraryURLs.map(\.path))
        let pruned = entries.filter { paths.contains($0.key) }
        if pruned.count != entries.count {
            entries = pruned
            saveToDisk()
        }

        let stale = libraryURLs.filter { !isCurrent($0) }
        task?.cancel()
        guard !stale.isEmpty else {
            task = nil
            isAnalyzing = false
            return
        }
        completed = 0
        total = stale.count
        isAnalyzing = true
        task = Task { await run(stale) }
    }

    private func run(_ urls: [URL]) async {
        var next = 0
        await withTaskGroup(of: (String, Entry).self) { group in
            func launchNext() {
                guard next < urls.count else { return }
                let url = urls[next]
                next += 1
                group.addTask(priority: .utility) { (url.path, await Self.analyze(url)) }
            }
            for _ in 0..<Self.concurrency { launchNext() }

            while let (path, entry) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                entries[path] = entry
                completed += 1
                // Save periodically so a quit mid-build keeps its progress.
                if completed % 25 == 0 { saveToDisk() }
                launchNext()
            }
        }
        guard !Task.isCancelled else { return }
        saveToDisk()
        isAnalyzing = false
        task = nil
    }

    // MARK: - Lookup

    // Linear gain (0...1) to multiply the player volume by for this song. Songs the index
    // hasn't reached yet are measured on the spot so playback never has to wait for the build.
    func gain(for url: URL) async -> Float {
        if isCurrent(url), let entry = entries[url.path] {
            return Self.gain(for: entry.level)
        }
        let entry = await Task.detached(priority: .utility) { await Self.analyze(url) }.value
        entries[url.path] = entry
        return Self.gain(for: entry.level)
    }

    private func isCurrent(_ url: URL) -> Bool {
        guard let entry = entries[url.path] else { return false }
        let print = Self.fingerprint(of: url)
        return entry.modified == print.modified && entry.size == print.size
    }

    private static func attenuation(for level: Float?) -> Float {
        guard let level else { return 0 }
        return min(max(level - targetLevel, 0), maxAttenuation)
    }

    private static func gain(for level: Float?) -> Float {
        powf(10, -attenuation(for: level) / 20)
    }

    // MARK: - Measuring

    private nonisolated static func fingerprint(of url: URL) -> (modified: Double, size: Int) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (values?.contentModificationDate?.timeIntervalSince1970 ?? 0, values?.fileSize ?? 0)
    }

    private nonisolated static func analyze(_ url: URL) async -> Entry {
        let print = fingerprint(of: url)
        return Entry(level: await measureLevel(of: url), modified: print.modified, size: print.size)
    }

    // Reads a slice from the middle of the song and returns its RMS level in dBFS.
    // Returns nil if the song can't be analyzed (or is pure silence).
    private nonisolated static func measureLevel(of url: URL) async -> Float? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        let total = (try? await asset.load(.duration))?.seconds ?? .nan
        if total.isFinite, total > sampleSeconds {
            let start = (total - sampleSeconds) / 2
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: sampleSeconds, preferredTimescale: 600)
            )
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var sumSquares: Double = 0
        var count: Int = 0
        while let buffer = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(buffer) }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for sample in data { sumSquares += Double(sample * sample) }
            count += data.count
        }

        guard count > 0, sumSquares > 0 else { return nil }
        let rms = Float((sumSquares / Double(count)).squareRoot())
        return 20 * log10(rms)
    }

    // MARK: - Persistence

    private nonisolated static var storeURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "ClassicTunes"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("stableVolume.v1.json")
    }

    private static func loadFromDisk() -> [String: Entry] {
        guard let url = storeURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return decoded
    }

    private func saveToDisk() {
        guard let url = Self.storeURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
