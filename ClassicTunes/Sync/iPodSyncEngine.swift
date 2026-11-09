import Foundation
import DiskArbitration
import AppKit
import Combine

// MARK: - iPod Device Model
// This file is hella cursed enough you can peruse around here to your liking

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
    case shuffle3 = "iPod Shuffle (3rd/4th gen)"
    case classic  = "iPod (Classic/Nano/Mini)"
    case unknown  = "iPod (Unknown)"
}

// MARK: - Device Monitor (DiskArbitration)

// Watches for USB volume mounts and identifies iPod Shuffles by filesystem fingerprint.
final class iPodDeviceMonitor: ObservableObject {
    @Published var connectedDevice: iPodDevice? = nil

    private var session: DASession?
    private let queue = DispatchQueue(label: "iPodDeviceMonitor", qos: .utility)

    init() {
        startMonitoring()
        observeSystemEvents()
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

        DARegisterDiskDescriptionChangedCallback(
            session,
            nil,
            [kDADiskDescriptionVolumePathKey] as CFArray,
            { disk, _, context in
                let monitor = Unmanaged<iPodDeviceMonitor>.fromOpaque(context!).takeUnretainedValue()
                monitor.handleDiskChanged(disk)
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

        // Check if this looks like an iPod
        guard let device = identifyiPodShuffle(at: mountURL, description: desc) else {
            if (desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool) == false {
                refresh(after: 1.5)
                refresh(after: 4)
            }
            return
        }

        DispatchQueue.main.async {
            self.connectedDevice = device
        }
    }

    private func handleDiskChanged(_ disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return }
        if desc[kDADiskDescriptionVolumePathKey as String] is URL {
            handleDiskAppeared(disk)
        } else {
            validateConnectedDevice()
        }
    }

    // The description of a disk that is going away often has no mount path any more, so matching
    // it against the connected device by path misses it and leaves a ghost device in the UI. Asking
    // whether the device's own volume still exists does not depend on that.
    private func handleDiskDisappeared(_ disk: DADisk) {
        print("iPodDeviceMonitor: disk disappeared")
        validateConnectedDevice()
    }

    func validateConnectedDevice() {
        DispatchQueue.main.async {
            if let device = self.connectedDevice, !FileManager.default.fileExists(atPath: device.volumeURL.path) {
                self.connectedDevice = nil
            }
        }
    }

    // Safety nets for events DiskArbitration misses: mount and unmount notices from the system, and
    // the app coming back to the foreground, which is when someone who plugged the iPod in while
    // the app was in the background looks at it.
    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(after: 0.5)
        }
        workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.validateConnectedDevice()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(after: 0)
        }
    }

    private func refresh(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.validateConnectedDevice()
            self?.scanMountedVolumes()
        }
    }

    // MARK: iPod Identification

    // Returns an iPodDevice if the volume looks like an iPod Shuffle, nil otherwise.
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
        var iTunesSDURL: URL?
        if let actualControlDir = controlDir {
            let iTunesDir = actualControlDir.appendingPathComponent("iTunes")
            let ITUNESDir = actualControlDir.appendingPathComponent("ITUNES")
            let actualITunesDir = fm.fileExists(atPath: iTunesDir.path) ? iTunesDir : ITUNESDir

            let sdPathCaps = actualITunesDir.appendingPathComponent("ITUNESSD")
            let sdPathLower = actualITunesDir.appendingPathComponent("iTunesSD")
            let dbPathCaps = actualITunesDir.appendingPathComponent("ITUNESDB")
            let dbPathLower = actualITunesDir.appendingPathComponent("iTunesDB")

            iTunesSDURL = [sdPathLower, sdPathCaps].first { fm.fileExists(atPath: $0.path) }
            hasiTunesSD = iTunesSDURL != nil
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

        // 5) Identify generation: the USB identity is authoritative; files are the fallback for
        // models it does not list (and for volumes with no USB parent).
        let generation: iPodGeneration
        if let usbGeneration = iPodUSBIdentity.generation(bsdName: bsdName) {
            generation = usbGeneration
        } else if hasiTunesSD {
            // iTunesSD wins when both files exist: Shuffles may carry an iTunesDB too. The two
            // Shuffle families store incompatible iTunesSD files, and the file's own tag is the
            // only way to tell them apart without USB identity.
            let head = iTunesSDURL.flatMap { try? FileHandle(forReadingFrom: $0) }
            let magic = (try? head?.read(upToCount: 4)) ?? nil
            try? head?.close()
            generation = magic == iTunesSD_LEDatabase.magic ? .shuffle3 : .shuffle2
        } else if hasiTunesDB {
            generation = .classic
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
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }
            let keys: [URLResourceKey] = [.volumeIsInternalKey]
            guard let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return }
            for url in volumes {
                // Internal volumes are the Mac's own disks; none of them is an iPod.
                if (try? url.resourceValues(forKeys: Set(keys)))?.volumeIsInternal == true { continue }
                // The real description, so the BSD name (needed for USB identification and the saved
                // access grant) is known instead of being left blank.
                guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                      let desc = DADiskCopyDescription(disk) as? [String: Any],
                      let device = self.identifyiPodShuffle(at: url, description: desc) else { continue }
                DispatchQueue.main.async {
                    if self.connectedDevice == nil { self.connectedDevice = device }
                }
                return
            }
        }
    }
}

// MARK: - Sync Engine

// Handles the actual file copy + database write operations.
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

    // Sync, add and remove live in Sync/SyncEngine.swift.

    // MARK: Filesystem flush

    func syncFilesystem(at url: URL) {
        // Open the volume and call fsync to flush dirty pages before eject
        if let fd = Darwin.open(url.path, O_RDONLY) as Int32?,
           fd >= 0 {
            _ = Darwin.fsync(fd)
            Darwin.close(fd)
        }
    }
    
    func setHidden(at url: URL) {
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = 0x40  // kIsInvisible
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            setxattr(path, "com.apple.FinderInfo", &finderInfo, 32, 0, 0)
        }
    }
    
    // MARK: Permissions Persistence
    func persistAccess(for url: URL, bsdName: String) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "iPodBookmark_\(bsdName)")
            self.grantedVolumeURL = url
        } catch {
            print("Failed to create security bookmark: \(error)")
        }
    }

    func loadPersistedAccess(for bsdName: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "iPodBookmark_\(bsdName)") else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            
            guard FileManager.default.fileExists(atPath: url.path) else {
                        UserDefaults.standard.removeObject(forKey: "iPodBookmark_\(bsdName)")
                        return nil
                    }
            
            if isStale {
                // Re-save if OS flagged it as stale
                persistAccess(for: url, bsdName: bsdName)
            }
            _ = url.startAccessingSecurityScopedResource()
            return url
        } catch {
            print("Failed to resolve bookmark: \(error)")
            return nil
        }
    }
}

// MARK: - Eject Helper

extension iPodSyncEngine {
    // Asks macOS to unmount and eject the iPod volume. Another process (Spotlight indexing the
    // volume, a Finder window) can briefly hold it, so a refusal is retried before it is reported.
    func eject(device: iPodDevice, completion: @escaping (Bool) -> Void) {
        Task {
            await MainActor.run { progress = SyncProgress(phase: .ejecting) }
            // Our own open access to the volume would otherwise count as "in use".
            grantedVolumeURL?.stopAccessingSecurityScopedResource()
            syncFilesystem(at: device.volumeURL)

            var failure: Error?
            for attempt in 0..<4 {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: device.volumeURL)
                    failure = nil
                    break
                } catch {
                    failure = error
                    print("Failed to eject iPod (attempt \(attempt + 1)): \(error.localizedDescription)")
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }

            if let failure {
                // Still plugged in, so the access the failed attempt gave up is needed again.
                _ = grantedVolumeURL?.startAccessingSecurityScopedResource()
                let message = "The iPod couldn't be ejected: \(failure.localizedDescription) Another app may be using it."
                await MainActor.run { progress = SyncProgress(phase: .failed(message)) }
            } else {
                await MainActor.run { progress = SyncProgress() }
            }
            completion(failure == nil)
        }
    }
}
