import Foundation

// A message meant for the user, thrown when a sync cannot or should not proceed.
struct SyncFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct PlacedFile {
    let url: URL
    // e.g. "/iPod_Control/Music/F03/ABCD.mp3"
    let devicePath: String
    let sizeBytes: Int
}

struct PlaylistRequest {
    let name: String
    // Identities (see SyncIdentity) in playlist order; ones not on the device are dropped.
    let identities: [String]
}

// The one interface the sync engine needs from a database format. Everything format-specific
// (iTunesSD for Shuffles, iTunesDB for the rest) lives behind it, so planning, copying, free
// space checks, backups and rollback are written once.
protocol DeviceLibrary: AnyObject {
    var entries: [DeviceEntry] { get }
    // Database files that are copied to the Mac before the first write.
    var databaseFiles: [URL] { get }
    var supportsPlaylists: Bool { get }

    // nil when the device can play the file, otherwise a reason shown to the user.
    func rejectionReason(for song: Song) async -> String?
    // Throws when this database must not be modified (signed, unknown index types, ...).
    func prepareForWrite() throws
    func add(_ song: Song, identity: String, placed: PlacedFile) async throws -> DeviceEntry
    func remove(_ entry: DeviceEntry) throws
    // True when a track already on the device lacks data the Mac copy has (e.g. a cover added by
    // a later ClassicTunes version), so it is re-added rather than left permanently incomplete.
    func needsRefresh(_ entry: DeviceEntry, for song: Song) -> Bool
    func writePlaylists(_ requests: [PlaylistRequest]) throws -> Int
    // Writes the database in one step; until this succeeds the device keeps its old one.
    func commit() throws
}

extension DeviceLibrary {
    func needsRefresh(_ entry: DeviceEntry, for song: Song) -> Bool { false }
}

enum DeviceFiles {
    static func url(base: URL, devicePath: String) -> URL {
        base.appendingPathComponent(String(devicePath.drop(while: { $0 == "/" })))
    }

    // iPods spread music over F00...Fnn so no directory grows past what the firmware can list;
    // reusing the folders already present keeps the layout iTunes or the device created.
    // `source` is a converted copy to place instead of the song's own file.
    static func place(_ song: Song, base: URL, source: URL? = nil) throws -> PlacedFile {
        let origin = source ?? song.url
        let fm = FileManager.default
        let musicBase = base.appendingPathComponent("iPod_Control/Music", isDirectory: true)
        let existing = ((try? fm.contentsOfDirectory(atPath: musicBase.path)) ?? [])
            .filter { $0.count == 3 && $0.hasPrefix("F") && Int($0.dropFirst()) != nil }
        let names = existing.isEmpty ? (0..<20).map { String(format: "F%02d", $0) } : existing
        let folderName = names.randomElement() ?? "F00"
        let folder = musicBase.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let ext = origin.pathExtension.lowercased()
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var fileName: String
        repeat {
            let stem = String((0..<4).map { _ in letters.randomElement()! })
            fileName = ext.isEmpty ? stem : "\(stem).\(ext)"
        } while fm.fileExists(atPath: folder.appendingPathComponent(fileName).path)

        let destination = folder.appendingPathComponent(fileName)
        try fm.copyItem(at: origin, to: destination)
        removeAppleDouble(for: destination)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return PlacedFile(url: destination, devicePath: "/iPod_Control/Music/\(folderName)/\(fileName)", sizeBytes: size)
    }

    // Copying onto FAT/HFS+ volumes can leave a "._name" companion file beside the copy. The
    // firmware has no use for it and it wastes a directory slot.
    static func removeAppleDouble(for url: URL) {
        let companion = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
        try? FileManager.default.removeItem(at: companion)
    }

    // A cheap write test before any real work. A saved permission can outlive the volume it was
    // granted for, and without this the first symptom is a database write failing half-way.
    static func preflight(base: URL) throws {
        let dir = base.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let probe = dir.appendingPathComponent(".classictunes-probe")
        do {
            try Data("probe".utf8).write(to: probe)
            let back = try Data(contentsOf: probe)
            try FileManager.default.removeItem(at: probe)
            guard back == Data("probe".utf8) else { throw SyncFailure("The iPod returned different data than was written to it.") }
        } catch let failure as SyncFailure {
            throw failure
        } catch {
            throw SyncFailure("ClassicTunes can't write to the iPod (\(error.localizedDescription)). Access to the volume will be requested again on the next sync.")
        }
    }

    // Writes, then reads back from the device: FAT volumes can accept a write the filesystem
    // later drops, and the firmware only ever sees what is really on the disk.
    static func writeVerified(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        guard (try? Data(contentsOf: url)) == data else {
            throw SyncFailure("\(url.lastPathComponent) did not read back correctly after writing; the iPod may be full or disconnecting.")
        }
        removeAppleDouble(for: url)
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func availableBytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let free = values.volumeAvailableCapacity else { return nil }
        return Int64(free)
    }
}

enum DatabaseBackups {
    private static let sessionsToKeep = 10

    // Backups live on the Mac, not the iPod, so a database that corrupts the device can still be
    // restored and the iPod's limited space is not spent on rollback copies.
    static func save(_ files: [URL], key: String) throws {
        let fm = FileManager.default
        let existing = files.filter { fm.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ClassicTunes", isDirectory: true)
            .appendingPathComponent("iPodBackups", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let session = root.appendingPathComponent(stamp, isDirectory: true)
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        for file in existing { try fm.copyItem(at: file, to: session.appendingPathComponent(file.lastPathComponent)) }

        let sessions = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in sessions.dropFirst(sessionsToKeep) { try? fm.removeItem(at: stale) }
    }
}
