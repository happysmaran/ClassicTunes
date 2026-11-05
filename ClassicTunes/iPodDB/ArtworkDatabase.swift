import Foundation
import ImageIO
import CoreGraphics

// One cover-art size the iPod can show, as the device itself declares it in SysInfoExtended.
struct ArtworkFormat: Equatable {
    let id: UInt32
    let width: Int
    let height: Int
    let rowBytes: Int
    var byteCount: Int { rowBytes * height }
}

// Appends album art to an iPod's existing Artwork/ArtworkDB and its F<format>_1.ithmb pixel files.
//
// Append-only on purpose: images already on the device (from iTunes or earlier syncs) keep their
// ids and offsets, so nothing the firmware has cached can point at moved data. Only 16-bit
// little-endian RGB formats are written; a device that declares anything else keeps its art
// untouched and the songs simply have none.
//
// A device with no ArtworkDB gets an empty one, laid out for the formats the device declares in
// SysInfoExtended or, when that file is missing too, for the  formats its model is known to use.
// The initialiser returns nil when no writable format is known, and the songs then sync without
// covers.
final class ArtworkDatabase {
    private let base: URL
    private var bytes: Data
    private let formats: [ArtworkFormat]
    private var nextImageID: UInt32

    private var pendingImages = Data()
    private var pendingCount = 0
    private var pendingPixels: [UInt32: Data] = [:]
    private var originalSizes: [UInt32: Int] = [:]
    // Tracks sharing a cover share its pixels; each still gets its own image record because a
    // record links to exactly one track.
    private var offsetsByArtwork: [Data: [UInt32: UInt32]] = [:]

    // Header of an image record as iTunes writes it: counts, ids, sizes patched per image.
    private static let imageHeaderHex = "6d6869699800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000010000000000000000000000000000000000f87f000000000000f87f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"

    static func databaseURL(base: URL) -> URL {
        base.appendingPathComponent("iPod_Control/Artwork/ArtworkDB")
    }

    static func pixelURL(base: URL, format: UInt32) -> URL {
        base.appendingPathComponent("iPod_Control/Artwork/F\(format)_1.ithmb")
    }

    // `fallbackFormats` covers iPods that have not yet had SysInfoExtended written (iTunes creates
    // it on first connect; a Finder restore does not).
    init?(base: URL, fallbackFormats: [ArtworkFormat] = []) {
        self.base = base
        var formats = Self.writableFormats(base: base)
        if formats.isEmpty { formats = fallbackFormats }
        guard !formats.isEmpty else { return nil }
        if let data = try? Data(contentsOf: Self.databaseURL(base: base)) {
            guard let next = data.readLE(UInt32.self, at: 0x1C),
                  (try? Self.imageDataset(in: data)) != nil else { return nil }
            self.bytes = data
            self.nextImageID = next
        } else {
            self.bytes = Self.emptyDatabase(formats: formats)
            // iTunes numbers images from 100; lower ids are reserved by the firmware.
            self.nextImageID = 100
        }
        self.formats = formats
        for format in formats {
            originalSizes[format.id] = Int(DeviceFiles.fileSize(Self.pixelURL(base: base, format: format.id)))
        }
    }

    var databaseFiles: [URL] { [Self.databaseURL(base: base)] }

    // MARK: Fresh database

    // An ArtworkDB holding no images: the file header, an empty image list, an empty album list
    // and the list of pixel-file formats the device uses.
    private static func emptyDatabase(formats: [ArtworkFormat]) -> Data {
        func chunk(_ tag: String, header size: Int, field8: Int, _ fill: (inout Data) -> Void = { _ in }) -> Data {
            var data = Data(count: size)
            data.replaceSubrange(0..<4, with: Array(tag.utf8))
            data.writeLE(UInt32(size), at: 4)
            data.writeLE(UInt32(field8), at: 8)
            fill(&data)
            return data
        }
        func dataset(_ type: Int, _ child: Data) -> Data {
            var data = chunk("mhsd", header: 96, field8: 96 + child.count) { $0.writeLE(UInt32(type), at: 12) }
            data.append(child)
            return data
        }
        var files = chunk("mhlf", header: 92, field8: formats.count)
        for format in formats {
            files.append(chunk("mhif", header: 124, field8: 124) {
                $0.writeLE(format.id, at: 16)
                $0.writeLE(UInt32(format.byteCount), at: 20)
            })
        }
        var body = dataset(1, chunk("mhli", header: 92, field8: 0))
        body.append(dataset(2, chunk("mhla", header: 92, field8: 0)))
        body.append(dataset(3, files))
        var root = chunk("mhfd", header: 132, field8: 132 + body.count) {
            $0.writeLE(UInt32(2), at: 16)
            $0.writeLE(UInt32(3), at: 20)
            $0.writeLE(UInt32(100), at: 0x1C)
            $0.writeLE(UInt32(2), at: 48)
        }
        root.append(body)
        return root
    }

    // MARK: Formats

    private static func writableFormats(base: URL) -> [ArtworkFormat] {
        let url = base.appendingPathComponent("iPod_Control/Device/SysInfoExtended")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let list = plist["AlbumArt"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let id = entry["FormatId"] as? Int,
                  entry["PixelFormat"] as? String == "RGB565_LE",
                  let width = entry["RenderWidth"] as? Int,
                  let height = entry["RenderHeight"] as? Int,
                  let rowBytes = entry["RowBytes"] as? Int,
                  width > 0, height > 0, rowBytes >= width * 2 else { return nil }
            return ArtworkFormat(id: UInt32(id), width: width, height: height, rowBytes: rowBytes)
        }
    }

    // MARK: Structure

    // Offset, total length and image count of the image-list dataset, after checking that the
    // datasets tile the file exactly. Anything else is not a file to append to.
    private static func imageDataset(in data: Data) throws -> (offset: Int, length: Int, images: Int) {
        guard data.count >= 132, data.prefix(4) == Data("mhfd".utf8),
              let headerLength = data.readLE(UInt32.self, at: 4), headerLength == 132,
              let total = data.readLE(UInt32.self, at: 8), Int(total) == data.count else {
            throw SyncFailure("The iPod's ArtworkDB is not in a layout ClassicTunes can extend.")
        }
        var cursor = Int(headerLength)
        var found: (Int, Int, Int)?
        while cursor < data.count {
            guard data.count - cursor >= 96,
                  data[cursor..<cursor + 4] == Data("mhsd".utf8),
                  let length = data.readLE(UInt32.self, at: cursor + 8), length >= 96,
                  cursor + Int(length) <= data.count,
                  let type = data.readLE(UInt32.self, at: cursor + 12) else {
                throw SyncFailure("The iPod's ArtworkDB has a damaged dataset.")
            }
            if type == 1 {
                let list = cursor + 96
                guard data[list..<list + 4] == Data("mhli".utf8),
                      let declared = data.readLE(UInt32.self, at: list + 8) else {
                    throw SyncFailure("The iPod's ArtworkDB has no image list.")
                }
                var item = list + 92
                var count = 0
                while item < cursor + Int(length) {
                    guard data[item..<item + 4] == Data("mhii".utf8),
                          let itemLength = data.readLE(UInt32.self, at: item + 8), itemLength >= 152 else {
                        throw SyncFailure("The iPod's ArtworkDB has a damaged image record.")
                    }
                    item += Int(itemLength)
                    count += 1
                }
                guard item == cursor + Int(length), count == Int(declared) else {
                    throw SyncFailure("The iPod's ArtworkDB image count does not match its records.")
                }
                found = (cursor, Int(length), count)
            }
            cursor += Int(length)
        }
        guard cursor == data.count, let found else {
            throw SyncFailure("The iPod's ArtworkDB has no image dataset.")
        }
        return (found.0, found.1, found.2)
    }

    // MARK: Adding

    // Queues `artwork` for a track and returns the source size the track record should carry,
    // or nil when the image cannot be decoded (the song just has no cover then).
    func add(_ artwork: Data, databaseTrackID: UInt64) throws -> Int? {
        guard let image = Self.decode(artwork) else { return nil }
        var offsets = offsetsByArtwork[artwork]
        if offsets == nil {
            var fresh: [UInt32: UInt32] = [:]
            for format in formats {
                var pixels = pendingPixels[format.id] ?? Data()
                let original = originalSizes[format.id] ?? 0
                if pixels.isEmpty {
                    // Records are addressed as whole images; a ragged existing file is realigned.
                    let remainder = original % format.byteCount
                    if remainder != 0 { pixels.append(Data(count: format.byteCount - remainder)) }
                }
                let offset = original + pixels.count
                guard offset <= Int(UInt32.max) - format.byteCount else {
                    throw SyncFailure("The iPod's artwork file is full.")
                }
                pixels.append(Self.rgb565(image, format: format))
                pendingPixels[format.id] = pixels
                fresh[format.id] = UInt32(offset)
            }
            offsetsByArtwork[artwork] = fresh
            offsets = fresh
        }
        guard let offsets else { return nil }
        pendingImages.append(imageRecord(id: nextImageID, trackID: databaseTrackID, sourceSize: artwork.count, offsets: offsets))
        nextImageID += 1
        pendingCount += 1
        return artwork.count
    }

    private func imageRecord(id: UInt32, trackID: UInt64, sourceSize: Int, offsets: [UInt32: UInt32]) -> Data {
        var children = Data()
        for format in formats {
            var name = Data()
            for unit in ":F\(format.id)_1.ithmb".utf16 { name.appendLE(unit) }
            var string = Data()
            string.append(contentsOf: Array("mhod".utf8))
            string.appendLE(UInt32(24)); string.appendLE(UInt32(24 + 12 + name.count))
            string.appendLE(UInt32(3)); string.appendLE(UInt64(0))
            string.appendLE(UInt32(name.count)); string.appendLE(UInt32(2)); string.appendLE(UInt32(0))
            string.append(name)

            var location = Data()
            location.append(contentsOf: Array("mhni".utf8))
            location.appendLE(UInt32(76)); location.appendLE(UInt32(76 + string.count))
            location.appendLE(UInt32(1))
            location.appendLE(format.id)
            location.appendLE(offsets[format.id] ?? 0)
            location.appendLE(UInt32(format.byteCount))
            location.appendLE(Int16(0)); location.appendLE(Int16(0))
            location.appendLE(UInt16(format.height)); location.appendLE(UInt16(format.width))
            location.appendLE(UInt32(0))
            location.appendLE(UInt32(format.byteCount))
            location.append(Data(count: 76 - location.count))
            location.append(string)

            var container = Data()
            container.append(contentsOf: Array("mhod".utf8))
            container.appendLE(UInt32(24)); container.appendLE(UInt32(24 + location.count))
            container.appendLE(UInt32(2)); container.appendLE(UInt64(0))
            container.append(location)
            children.append(container)
        }
        // The empty auxiliary record iTunes writes after the thumbnails.
        var auxiliary = Data()
        auxiliary.append(contentsOf: Array("mhod".utf8))
        auxiliary.appendLE(UInt32(24)); auxiliary.appendLE(UInt32(120))
        auxiliary.appendLE(UInt32(6)); auxiliary.appendLE(UInt64(0))
        auxiliary.append(contentsOf: Array("mhaf".utf8))
        auxiliary.appendLE(UInt32(96)); auxiliary.appendLE(UInt32(60))
        auxiliary.append(Data(count: 120 - auxiliary.count))
        children.append(auxiliary)

        var record = Self.hexData(Self.imageHeaderHex)
        record.writeLE(UInt32(record.count + children.count), at: 8)
        record.writeLE(UInt32(formats.count + 1), at: 0x0C)
        record.writeLE(id, at: 0x10)
        record.writeLE(trackID, at: 0x14)
        record.writeLE(UInt32(clamping: sourceSize), at: 0x30)
        record.append(children)
        return record
    }

    // MARK: Writing

    // Pixels first, then the ArtworkDB that points at them, so a failure part-way leaves unused
    // pixel data at the end of a file instead of records pointing at nothing.
    func commit() throws {
        guard pendingCount > 0 else { return }
        try FileManager.default.createDirectory(
            at: Self.databaseURL(base: base).deletingLastPathComponent(), withIntermediateDirectories: true)
        for format in formats {
            guard let pixels = pendingPixels[format.id], !pixels.isEmpty else { continue }
            let url = Self.pixelURL(base: base, format: format.id)
            let expected = (originalSizes[format.id] ?? 0) + pixels.count
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: pixels)
            try handle.synchronize()
            guard Int(DeviceFiles.fileSize(url)) == expected else {
                throw SyncFailure("\(url.lastPathComponent) did not grow as expected; the iPod may be full or disconnecting.")
            }
            DeviceFiles.removeAppleDouble(for: url)
        }

        let layout = try Self.imageDataset(in: bytes)
        var updated = bytes
        updated.insert(contentsOf: pendingImages, at: layout.offset + layout.length)
        updated.writeLE(UInt32(updated.count), at: 8)
        updated.writeLE(nextImageID, at: 0x1C)
        updated.writeLE(UInt32(layout.length + pendingImages.count), at: layout.offset + 8)
        updated.writeLE(UInt32(layout.images + pendingCount), at: layout.offset + 96 + 8)
        let check = try Self.imageDataset(in: updated)
        guard check.images == layout.images + pendingCount else {
            throw SyncFailure("The new ArtworkDB failed its own consistency check; it was not written.")
        }
        try DeviceFiles.writeVerified(updated, to: Self.databaseURL(base: base))
        bytes = updated
        for (format, pixels) in pendingPixels { originalSizes[format, default: 0] += pixels.count }
        pendingPixels = [:]
        offsetsByArtwork = [:]
        pendingImages = Data()
        pendingCount = 0
    }

    // MARK: Pixels

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // Fitted without cropping and centred on black, as the firmware shows it unscaled.
    private static func rgb565(_ image: CGImage, format: ArtworkFormat) -> Data {
        let width = format.width, height = format.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
            let w = max(1, (Double(image.width) * scale).rounded())
            let h = max(1, (Double(image.height) * scale).rounded())
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
            return true
        }
        var out = Data(count: format.byteCount)
        guard drawn else { return out }
        for row in 0..<height {
            for column in 0..<width {
                let i = (row * width + column) * 4
                let r = UInt16(rgba[i] >> 3), g = UInt16(rgba[i + 1] >> 2), b = UInt16(rgba[i + 2] >> 3)
                let value = (r << 11) | (g << 5) | b
                let o = row * format.rowBytes + column * 2
                out[o] = UInt8(value & 0xFF)
                out[o + 1] = UInt8(value >> 8)
            }
        }
        return out
    }

    private static func hexData(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }
}
