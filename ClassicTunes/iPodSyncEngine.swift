import Foundation
import DiskArbitration
import AppKit
import Combine

// MARK: - iPod Device Model

struct iPodDevice: Identifiable, Equatable {
    let id: UUID = UUID()
    let volumeURL: URL          // e.g. /Volumes/IPOD
    let volumeName: String      // e.g. "IPOD"
    let bsdName: String         // e.g. "disk2s1"
    var generation: iPodGeneration = .unknown
    var capacity: Int64 = 0     // bytes
    var freeSpace: Int64 = 0    // bytes

    static func == (lhs: iPodDevice, rhs: iPodDevice) -> Bool {
        lhs.volumeURL == rhs.volumeURL
    }
}

enum iPodGeneration: String {
    case shuffle1 = "iPod Shuffle (1st gen)"
    case shuffle2 = "iPod Shuffle (2nd gen)"
    case classic  = "iPod (Classic/Nano/Mini)"
    case unknown  = "iPod (Unknown)"
}

// MARK: - Device Monitor (DiskArbitration)

/// Watches for USB volume mounts and identifies iPod Shuffles by filesystem fingerprint.
final class iPodDeviceMonitor: ObservableObject {
    @Published var connectedDevice: iPodDevice? = nil

    private var session: DASession?
    private let queue = DispatchQueue(label: "iPodDeviceMonitor", qos: .utility)

    init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: DiskArbitration Setup

    private func startMonitoring() {
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else { return }

        DASessionSetDispatchQueue(session, queue)

        // Register for disk appearance (covers already-mounted volumes on launch)
        DARegisterDiskAppearedCallback(
            session,
            [kDADiskDescriptionVolumeMountableKey: true] as CFDictionary,
            { disk, context in
                let monitor = Unmanaged<iPodDeviceMonitor>.fromOpaque(context!).takeUnretainedValue()
                monitor.handleDiskAppeared(disk)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        // Register for disk disappearance
        DARegisterDiskDisappearedCallback(
            session,
            nil,
            { disk, context in
                let monitor = Unmanaged<iPodDeviceMonitor>.fromOpaque(context!).takeUnretainedValue()
                monitor.handleDiskDisappeared(disk)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func stopMonitoring() {
        session = nil
    }

    // MARK: Callbacks

    private func handleDiskAppeared(_ disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return }

        // Only care about volumes with a mount point
        guard let mountURL = (desc[kDADiskDescriptionVolumePathKey as String] as? URL) else { return }

        print("iPodDeviceMonitor: disk appeared at \(mountURL.path)")

        // Check if this looks like an iPod Shuffle
        guard let device = identifyiPodShuffle(at: mountURL, description: desc) else { return }

        DispatchQueue.main.async {
            self.connectedDevice = device
        }
    }

    private func handleDiskDisappeared(_ disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              let mountURL = desc[kDADiskDescriptionVolumePathKey as String] as? URL else { return }

        print("iPodDeviceMonitor: disk disappeared at \(mountURL.path)")

        DispatchQueue.main.async {
            if self.connectedDevice?.volumeURL == mountURL {
                self.connectedDevice = nil
            }
        }
    }

    // MARK: iPod Identification

    /// Returns an iPodDevice if the volume looks like an iPod Shuffle, nil otherwise.
    private func identifyiPodShuffle(at url: URL, description: [String: Any]) -> iPodDevice? {
        let fm = FileManager.default

        // 1) Gather DiskArbitration hints
        let volumeName = (description[kDADiskDescriptionVolumeNameKey as String] as? String) ?? url.lastPathComponent
        let bsdName    = (description[kDADiskDescriptionMediaBSDNameKey as String] as? String) ?? ""
        let model      = (description[kDADiskDescriptionDeviceModelKey as String] as? String) ?? ""
        let vendor     = (description[kDADiskDescriptionDeviceVendorKey as String] as? String) ?? ""

        // 2) Probe filesystem markers if we can (case variants included)
        let possibleControlPaths = [
            url.appendingPathComponent("iPod_Control"),
            url.appendingPathComponent("IPOD_CONTROL")
        ]
        let controlDir = possibleControlPaths.first { fm.fileExists(atPath: $0.path) }

        var hasiTunesSD = false
        var hasiTunesDB = false
        if let actualControlDir = controlDir {
            let iTunesDir = actualControlDir.appendingPathComponent("iTunes")
            let ITUNESDir = actualControlDir.appendingPathComponent("ITUNES")
            let actualITunesDir = fm.fileExists(atPath: iTunesDir.path) ? iTunesDir : ITUNESDir

            let sdPathCaps = actualITunesDir.appendingPathComponent("ITUNESSD")
            let sdPathLower = actualITunesDir.appendingPathComponent("iTunesSD")
            let dbPathCaps = actualITunesDir.appendingPathComponent("ITUNESDB")
            let dbPathLower = actualITunesDir.appendingPathComponent("iTunesDB")

            hasiTunesSD = fm.fileExists(atPath: sdPathCaps.path) || fm.fileExists(atPath: sdPathLower.path)
            hasiTunesDB = fm.fileExists(atPath: dbPathCaps.path) || fm.fileExists(atPath: dbPathLower.path)
        }

        // 3) Decide if this looks like an iPod at all
        let looksLikeIPodByFS = (controlDir != nil) || hasiTunesSD || hasiTunesDB
        let looksLikeIPodByDA = model.localizedCaseInsensitiveContains("ipod") ||
                                vendor.localizedCaseInsensitiveContains("ipod") ||
                                volumeName.localizedCaseInsensitiveContains("ipod")
        guard looksLikeIPodByFS || looksLikeIPodByDA else { return nil }

        // 4) Determine capacity/free space (best-effort)
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let capacity  = Int64(values?.volumeTotalCapacity  ?? 0)
        let freeSpace = Int64(values?.volumeAvailableCapacity ?? 0)

        // 5) Identify generation: prefer concrete filesystem hints
        let generation: iPodGeneration
        if hasiTunesDB {
            generation = .classic
        } else if hasiTunesSD {
            generation = .shuffle2
        } else if controlDir != nil {
            generation = .shuffle1 // early shuffles had no iTunesSD until first sync
        } else {
            generation = .unknown
        }

        let device = iPodDevice(
            volumeURL: url,
            volumeName: volumeName,
            bsdName: bsdName,
            generation: generation,
            capacity: capacity,
            freeSpace: freeSpace
        )

        // Debug print so we can see detection in the console
        print("iPodDeviceMonitor: Detected potential iPod at \(url.path) — generation: \(device.generation.rawValue)")
        return device
    }

    // MARK: Manual Scan (called on app launch to catch already-mounted devices)

    func scanMountedVolumes() {
        let fm = FileManager.default
        guard let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [], options: []) else { return }
        for url in volumes {
            print("iPodDeviceMonitor: scanning mounted volume \(url.path)")
            // Build a minimal description dict for already-mounted volumes
            let name = url.lastPathComponent
            let desc: [String: Any] = [
                kDADiskDescriptionVolumePathKey as String: url,
                kDADiskDescriptionVolumeNameKey as String: name
            ]
            if let device = identifyiPodShuffle(at: url, description: desc) {
                DispatchQueue.main.async {
                    if self.connectedDevice == nil {
                        self.connectedDevice = device
                    }
                }
            }
        }
    }
}

// MARK: - Sync Engine

/// Handles the actual file copy + database write operations.
final class iPodSyncEngine: ObservableObject {
    var grantedVolumeURL: URL? = nil
    // MARK: Progress reporting

    struct SyncProgress {
        var phase: Phase = .idle
        var currentTrack: String = ""
        var completedTracks: Int = 0
        var totalTracks: Int = 0
        var bytesWritten: Int64 = 0

        enum Phase: Equatable {
            case idle
            case reading
            case copying
            case writing
            case ejecting
            case done
            case failed(String)
        }

        var isActive: Bool {
            switch phase {
            case .idle, .done, .failed: return false
            default: return true
            }
        }

        var fractionComplete: Double {
            guard totalTracks > 0 else { return 0 }
            return Double(completedTracks) / Double(totalTracks)
        }
    }

    @Published var progress = SyncProgress()

    // MARK: Music folder on device

    /// Returns (or creates) the /iPod_Control/Music/F00/ folder.
    /// Gen 1/2 Shuffle only uses a single flat subdirectory.
    private func musicFolder(on device: iPodDevice) throws -> URL {
        let folder = grantedVolumeURL ?? device.volumeURL
            .appendingPathComponent("iPod_Control/Music/F00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Returns (or creates) the /iPod_Control/iTunes/ folder.
    private func iTunesFolder(on device: iPodDevice) throws -> URL {
        let folder = grantedVolumeURL ?? device.volumeURL
            .appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: Read existing database

    func readDatabase(from device: iPodDevice) throws -> iPodShuffleDatabase {
        let dbURL = grantedVolumeURL ?? device.volumeURL
            .appendingPathComponent("iPod_Control/iTunes/iTunesSD")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            // Brand-new or never-synced device — start empty
            return iPodShuffleDatabase()
        }
        let data = try Data(contentsOf: dbURL)
        return try iPodShuffleDatabase.parse(from: data)
    }

    // MARK: Full sync

    /// Syncs `songs` to the device, replacing all existing tracks.
    /// - Parameters:
    ///   - songs: Songs to write (in desired playback order).
    ///   - device: The mounted iPod Shuffle.
    func sync(songs: [Song], to device: iPodDevice) async {
        let accessURL: URL? = await MainActor.run {
            let panel = NSOpenPanel()
            panel.message = "ClassicTunes needs access to your iPod to sync music."
            panel.prompt = "Grant Access"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = device.volumeURL
            panel.runModal()  // synchronous — blocks main thread briefly but guarantees result
            return panel.url
        }
        
        guard let volumeURL = accessURL else {
                await MainActor.run {
                    progress.phase = .failed("Access to iPod was denied.")
                }
                return
            }
        
        await MainActor.run {
            progress = SyncProgress(phase: .copying, totalTracks: songs.count)
        }

        do {
            let fm = FileManager.default
            let musicDir = try musicFolder(on: device)
            let itunesDir = try iTunesFolder(on: device)

            // 1. Remove all existing tracks from /iPod_Control/Music/f00/
            let existing = (try? fm.contentsOfDirectory(at: musicDir, includingPropertiesForKeys: nil)) ?? []
            for file in existing {
                try? fm.removeItem(at: file)
            }

            // 2. Copy each song and build track entries
            var db = iPodShuffleDatabase()
            var index = 0

            for song in songs {
                let songName = song.title.isEmpty ? song.url.lastPathComponent : song.title
                await MainActor.run {
                    progress.currentTrack = songName
                    progress.completedTracks = index
                }

                // Generate destination filename: 4-char uppercase hex index
                let destName = String(format: "%04X", index) + "." + song.url.pathExtension
                let destURL  = musicDir.appendingPathComponent(destName)

                // Copy the audio file
                do {
                    if fm.fileExists(atPath: destURL.path) {
                        try fm.removeItem(at: destURL)
                    }
                    try fm.copyItem(at: song.url, to: destURL)
                } catch {
                    // Skip this track rather than aborting the whole sync
                    print("iPodSync: skipped \(song.title): \(error.localizedDescription)")
                    index += 1
                    continue
                }

                // Build track entry
                // Path on device is relative to volume root: /iPod_Control/Music/f00/XXXX.ext
                var track = iTunesSDTrack()
                track.filePath    = "/iPod_Control/Music/F00/\(destName)"
                track.fileType    = iPodShuffleDatabase.fileType(for: song.url)
                track.volume      = 0x59     // 89 ≈ 100%
                track.shuffleFlag = 0x01
                track.podcastFlag = 0x00

                // Honour song duration for stopPositionMS (0 = play to end, which is fine)
                track.stopPositionMS = 0

                db.tracks.append(track)

                let fileSize = (try? destURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                await MainActor.run {
                    progress.bytesWritten += fileSize
                }

                index += 1
            }

            // 3. Write iTunesSD atomically
            await MainActor.run { progress.phase = .writing }

            let dbURL    = itunesDir.appendingPathComponent("iTunesSD")
            let statsURL = itunesDir.appendingPathComponent("iTunesStats")

            // Write to app's own tmp dir first (always writable), then copy onto the volume.
            // Writing .tmp directly into /iPod_Control/iTunes/ is blocked by macOS even
            // without sandboxing because the folder is treated as a system-ish directory.
            let appTmp   = URL(fileURLWithPath: NSTemporaryDirectory())
            let tmpDB    = appTmp.appendingPathComponent("iTunesSD.tmp")
            let tmpStats = appTmp.appendingPathComponent("iTunesStats.tmp")

            let serialised = db.serialise()
            try serialised.write(to: tmpDB, options: .atomic)

            // Copy DB onto device then clean up local tmp
            if fm.fileExists(atPath: dbURL.path) { try? fm.removeItem(at: dbURL) }
            try fm.copyItem(at: tmpDB, to: dbURL)
            try? fm.removeItem(at: tmpDB)

            // 4. Also write an empty iTunesStats so the device resets play counts
            writeEmptyiTunesStats(trackCount: db.tracks.count, to: tmpStats)
            if fm.fileExists(atPath: statsURL.path) { try? fm.removeItem(at: statsURL) }
            try? fm.copyItem(at: tmpStats, to: statsURL)
            try? fm.removeItem(at: tmpStats)

            // 5. Flush to disk (sync) then notify the OS to eject cleanly
            await MainActor.run { progress.phase = .ejecting }
            syncFilesystem(at: device.volumeURL)

            await MainActor.run {
                progress.phase = .done
                progress.completedTracks = songs.count
            }

        } catch {
            await MainActor.run {
                progress.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Add / Remove individual tracks

    /// Appends a single song without disturbing existing tracks.
    func addTrack(_ song: Song, to device: iPodDevice) async throws {
        var db = try readDatabase(from: device)

        let musicDir  = try musicFolder(on: device)
        let itunesDir = try iTunesFolder(on: device)
        let fm        = FileManager.default

        let nextIndex = db.tracks.count
        let destName  = String(format: "%04X", nextIndex) + "." + song.url.pathExtension
        let destURL   = musicDir.appendingPathComponent(destName)

        if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
        try fm.copyItem(at: song.url, to: destURL)

        var track = iTunesSDTrack()
        track.filePath    = "/iPod_Control/Music/F00/\(destName)"
        track.fileType    = iPodShuffleDatabase.fileType(for: song.url)
        track.volume      = 0x59
        track.shuffleFlag = 0x01
        db.tracks.append(track)

        let dbURL  = itunesDir.appendingPathComponent("iTunesSD")
        let tmpDB  = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iTunesSD.tmp")
        try db.serialise().write(to: tmpDB, options: .atomic)
        if fm.fileExists(atPath: dbURL.path) { try? fm.removeItem(at: dbURL) }
        try fm.copyItem(at: tmpDB, to: dbURL)
        try? fm.removeItem(at: tmpDB)
    }

    /// Removes a track by index and compacts the database.
    func removeTrack(at trackIndex: Int, from device: iPodDevice) async throws {
        var db = try readDatabase(from: device)
        guard trackIndex < db.tracks.count else { return }

        let fm       = FileManager.default
        let musicDir = try musicFolder(on: device)
        let itunesDir = try iTunesFolder(on: device)

        // Remove the audio file
        let track   = db.tracks[trackIndex]
        let fileURL = device.volumeURL.appendingPathComponent(
            String(track.filePath.drop(while: { $0 == "/" }))
        )
        try? fm.removeItem(at: fileURL)

        // Remove from db and renumber remaining tracks
        db.tracks.remove(at: trackIndex)

        // Renumber files on disk to stay sequential (optional but keeps things tidy)
        for (i, var t) in db.tracks.enumerated() {
            let ext      = (t.filePath as NSString).pathExtension
            let newName  = String(format: "%04X", i) + "." + ext
            let oldURL   = device.volumeURL.appendingPathComponent(
                String(t.filePath.drop(while: { $0 == "/" }))
            )
            let newURL   = musicDir.appendingPathComponent(newName)
            if oldURL != newURL {
                try? fm.moveItem(at: oldURL, to: newURL)
            }
            t.filePath   = "/iPod_Control/Music/F00/\(newName)"
            db.tracks[i] = t
        }

        let dbURL  = itunesDir.appendingPathComponent("iTunesSD")
        let tmpDB  = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iTunesSD.tmp")
        try db.serialise().write(to: tmpDB, options: .atomic)
        if fm.fileExists(atPath: dbURL.path) { try? fm.removeItem(at: dbURL) }
        try fm.copyItem(at: tmpDB, to: dbURL)
        try? fm.removeItem(at: tmpDB)
    }

    // MARK: iTunesStats

    /// iTunesStats layout (Gen 1/2 Shuffle):
    ///   Header: 18 bytes (same structure as iTunesSD header — track count + 0x0100 + zeros)
    ///   Per track: 18 bytes
    ///     Bytes 0–2:  bookmarkPositionMS (uint24 BE) — write 0
    ///     Bytes 3–5:  skipCount          (uint24 BE) — write 0
    ///     Bytes 6–8:  playCount          (uint24 BE) — write 0
    ///     Bytes 9–17: padding            (zeros)
    private func writeEmptyiTunesStats(trackCount: Int, to url: URL) {
        var data = Data(capacity: 18 + trackCount * 18)

        // Header
        data.append(UInt8((trackCount >> 16) & 0xFF))
        data.append(UInt8((trackCount >> 8)  & 0xFF))
        data.append(UInt8( trackCount        & 0xFF))
        data.append(contentsOf: [0x01, 0x00])
        data.append(contentsOf: [UInt8](repeating: 0, count: 13))

        // Empty track stats
        data.append(contentsOf: [UInt8](repeating: 0, count: trackCount * 18))

        try? data.write(to: url, options: .atomic)
    }

    // MARK: Filesystem flush

    private func syncFilesystem(at url: URL) {
        // Open the volume and call fsync to flush dirty pages before eject
        if let fd = Darwin.open(url.path, O_RDONLY) as Int32?,
           fd >= 0 {
            _ = Darwin.fsync(fd)
            Darwin.close(fd)
        }
    }
}

// MARK: - Eject Helper

extension iPodSyncEngine {
    // Asks macOS to unmount and eject the iPod volume safely.
    func eject(device: iPodDevice, completion: @escaping (Bool) -> Void) {
        let workspace = NSWorkspace.shared
        
        do {
            try workspace.unmountAndEjectDevice(at: device.volumeURL)
            completion(true)
        } catch {
            print("Failed to eject iPod: \(error.localizedDescription)")
            completion(false)
        }
    }
}
