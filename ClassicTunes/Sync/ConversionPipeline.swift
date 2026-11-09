import Foundation

// Converting is CPU-bound and copying to the iPod is I/O-bound, so this pipeline converts the
// next few songs in parallel, while the current one is being copied.
actor ConversionPipeline {
    enum Outcome {
        case original
        case converted(URL)
        case unusable(String)
    }

    // FLAC is not decodable by any iPod, so it has to be converted whatever the bitrate limit says.
    static let flacDefaultBitrateKbps = 256

    static func mustConvert(_ url: URL) -> Bool { url.pathExtension.lowercased() == "flac" }

    // What a song will occupy on the iPod, for the free-space check before anything is copied.
    @MainActor
    static func estimatedSize(url: URL, durationMS: UInt32, limitKbps: Int?) -> Int64 {
        guard mustConvert(url) else { return DeviceFiles.fileSize(url) }
        let rate = limitKbps.flatMap { $0 > 0 ? $0 : nil } ?? flacDefaultBitrateKbps
        return Int64(durationMS) * Int64(rate) / 8
    }

    struct Item {
        let index: Int
        let url: URL
        let title: String
    }

    private let items: [Item]
    private let limitKbps: Int?
    private let window: Int
    private var tasks: [Int: Task<Outcome, Never>] = [:]
    private var started = 0

    init(items: [Item], limitKbps: Int?) {
        self.items = items
        self.limitKbps = limitKbps
        window = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1))
    }

    // The result for the song at `position` in the order given to the initializer.
    func outcome(at position: Int) async -> Outcome {
        while started < items.count && started < position + window {
            let item = items[started]
            let limit = limitKbps
            tasks[started] = Task.detached { await Self.convert(item, limitKbps: limit) }
            started += 1
        }
        guard let task = tasks.removeValue(forKey: position) else { return .original }
        return await task.value
    }

    // Removes temporary files of conversions nobody collected, after a failure or when finished.
    func discardPending() async {
        for task in tasks.values {
            if case let .converted(url) = await task.value { try? FileManager.default.removeItem(at: url) }
        }
        tasks = [:]
    }

    // A failed or not-smaller conversion of a playable format falls back to the original so one
    // odd file never stops the sync; a FLAC has no playable original to fall back to.
    // Main-actor because the helpers it calls are; the encoding itself runs off the main actor.
    @MainActor
    private static func convert(_ item: Item, limitKbps: Int?) async -> Outcome {
        let forced = mustConvert(item.url)
        let target: Int
        if forced {
            target = limitKbps.flatMap { $0 > 0 ? $0 : nil } ?? flacDefaultBitrateKbps
        } else {
            guard let limit = limitKbps, limit > 0 else { return .original }
            let rate = Int(await ClassicBackend.audioProperties(for: item.url).bitrateKbps)
            guard rate > limit else { return .original }
            target = limit
        }
        do {
            let output = try await AudioTranscoder.convertToAAC(item.url, bitrateKbps: target)
            let before = DeviceFiles.fileSize(item.url), after = DeviceFiles.fileSize(output)
            if !forced && after >= before {
                try? FileManager.default.removeItem(at: output)
                return .original
            }
            SyncLog.record("converted \(item.title) to \(target) kbps AAC (\(before) -> \(after) bytes)")
            return .converted(output)
        } catch {
            SyncLog.record("conversion failed for \(item.title): \(error.localizedDescription)")
            return forced ? .unusable("conversion failed: \(error.localizedDescription)") : .original
        }
    }
}
