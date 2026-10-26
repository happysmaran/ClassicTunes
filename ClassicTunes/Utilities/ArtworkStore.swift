import AppKit
import CryptoKit
import ImageIO

// A content-addressed, on-disk store for album artwork.
//
// Songs used to embed their artwork bytes directly, so every track of an album carried its own
// copy of the same image in memory, in every playlist containing it, in drag payloads and in the
// saved playlists file. A song now holds only a short `artworkKey` (a hash of the image bytes),
// so identical artwork is stored once no matter how many songs use it.
nonisolated final class ArtworkStore: @unchecked Sendable {

    static let shared = ArtworkStore()

    // Where the image files live, or `nil` if Application Support is unavailable (memory-only then).
    private let directory: URL?

    // Raw bytes and decoded images are cached separately; both are cost-limited so memory stays
    // bounded however large the library is. `NSCache` is thread-safe and evicts under pressure.
    private let dataCache = NSCache<NSString, NSData>()
    private let imageCache = NSCache<NSString, NSImage>()

    init(directory: URL? = ArtworkStore.defaultDirectory) {
        self.directory = directory
        dataCache.totalCostLimit = 64 * 1024 * 1024
        imageCache.totalCostLimit = 128 * 1024 * 1024
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // `~/Library/Application Support/<bundle id>/Artwork`.
    static var defaultDirectory: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "ClassicTunes"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
    }

    // MARK: - Storing and reading

    // Saves the image bytes (if they aren't stored already) and returns the key that identifies them.
    @discardableResult
    func store(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let key = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        dataCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        if let url = fileURL(for: key), !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        }
        return key
    }

    // Whether the image for `key` can still be read (it may be missing if the cache folder was cleared).
    func contains(_ key: String) -> Bool {
        if dataCache.object(forKey: key as NSString) != nil { return true }
        guard let url = fileURL(for: key) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // The original image bytes for `key`.
    func data(for key: String) -> Data? {
        if let cached = dataCache.object(forKey: key as NSString) { return cached as Data }
        guard let url = fileURL(for: key), let data = try? Data(contentsOf: url) else { return nil }
        dataCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    // The full-size decoded image, cached so views don't decode the same bytes on every render.
    func image(for key: String) -> NSImage? {
        let cacheKey = key as NSString
        if let cached = imageCache.object(forKey: cacheKey) { return cached }
        guard let data = data(for: key), let image = NSImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: cacheKey, cost: data.count)
        return image
    }

    // A downscaled copy for grids and lists, so a screenful of covers doesn't mean a screenful of
    // full-resolution decodes.
    func thumbnail(for key: String, maxPixelSize: Int) -> NSImage? {
        let cacheKey = "\(key)@\(maxPixelSize)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) { return cached }
        guard let data = data(for: key), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        imageCache.setObject(image, forKey: cacheKey, cost: cgImage.width * cgImage.height * 4)
        return image
    }

    // MARK: - Cleanup

    // Deletes stored images that no song references any more (covers that were replaced or removed,
    // songs that left the library, store-preview artwork).
    //
    // - Parameters:
    //   - referenced: Every key still in use. Anything else is a candidate for deletion.
    //   - minimumAge: Unreferenced files newer than this are kept, so artwork that was just written
    //     by a scan or edit that `referenced` doesn't know about yet can't be deleted underneath it.
    // - Returns: How many files were deleted.
    @discardableResult
    func prune(keeping referenced: Set<String>, minimumAge: TimeInterval = 24 * 60 * 60) -> Int {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return 0 }

        let cutoff = Date().addingTimeInterval(-minimumAge)
        var removed = 0
        for file in files {
            let key = file.lastPathComponent
            guard !referenced.contains(key) else { continue }
            // If the age can't be determined, leave the file alone.
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil {
                dataCache.removeObject(forKey: key as NSString)
                imageCache.removeObject(forKey: key as NSString)
                removed += 1
            }
        }
        return removed
    }

    private func fileURL(for key: String) -> URL? {
        directory?.appendingPathComponent(key)
    }
}
