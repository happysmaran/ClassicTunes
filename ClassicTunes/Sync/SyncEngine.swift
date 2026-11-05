import Foundation
import AppKit

extension iPodSyncEngine {
    // MARK: Entry points

    // Default per device family: see SyncMode.
    static func defaultMode(for generation: iPodGeneration) -> SyncMode {
        generation == .classic ? .additive : .mirror
    }

    func openLibrary(for device: iPodDevice, base: URL) throws -> DeviceLibrary {
        switch device.generation {
        case .classic: return try ClassicLibrary(base: base)
        case .shuffle3: return try ShuffleLELibrary(base: base)
        case .shuffle1, .shuffle2: return try ShuffleLibrary(base: base)
        // Writing the wrong database format can leave an iPod unreadable, so a device whose model
        // could not be determined is obviously not written to.
        case .unknown: throw SyncFailure("ClassicTunes couldn't tell which iPod model this is, so it won't write to it. Restore it in Finder first, then reconnect.")
        }
    }

    // Asks for access to the volume only when none was granted before; the grant is remembered
    // so later syncs don't interrupt the user.
    @MainActor
    func resolveAccess(for device: iPodDevice) -> URL? {
        if let url = grantedVolumeURL { return url }
        if let saved = loadPersistedAccess(for: device.bsdName) {
            grantedVolumeURL = saved
            return saved
        }
        let panel = NSOpenPanel()
        panel.message = NSLocalizedString("sync.access.messageSync", comment: "")
        panel.prompt = NSLocalizedString("sync.access.prompt", comment: "")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = device.volumeURL
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        persistAccess(for: url, bsdName: device.bsdName)
        grantedVolumeURL = url
        return url
    }

    // Drops a saved permission that no longer works so the next sync asks again.
    func forgetAccess(for device: iPodDevice) {
        UserDefaults.standard.removeObject(forKey: "iPodBookmark_\(device.bsdName)")
        grantedVolumeURL = nil
    }

    // Both sync and rollback backups are filed under the same device key.
    private func backupKey(for device: iPodDevice) -> String {
        device.bsdName.isEmpty ? device.volumeName : device.bsdName
    }

    private func identity(of song: Song) async -> String {
        SyncIdentity.make(title: song.title, artist: song.artist, album: song.album, durationMS: await ClassicBackend.durationMS(of: song))
    }

    private func setPhase(_ phase: SyncProgress.Phase) async { await MainActor.run { progress.phase = phase } }

    // MARK: Sync

    // Reads the device, works out what differs from `songs`, then applies only that difference
    // and writes the database once at the end.
    func sync(songs: [Song], playlists: [Playlist] = [], to device: iPodDevice, mode: SyncMode? = nil) async {
        guard let base = await resolveAccess(for: device) else {
            await setPhase(.failed(NSLocalizedString("sync.access.denied", comment: "")))
            return
        }
        await MainActor.run { progress = SyncProgress(phase: .reading, totalTracks: 0) }
        let mode = mode ?? Self.defaultMode(for: device.generation)
        SyncLog.beginSession("sync \(device.volumeName) [\(device.generation.rawValue)] mode=\(mode) songs=\(songs.count) playlists=\(playlists.count)")
        SyncLog.record("volume access: \(base.path)")
        let fm = FileManager.default
        var copied: [URL] = []

        do {
            // Mirroring an empty selection would erase the device, which is never what an empty
            // list means.
            if mode == .mirror && songs.isEmpty { throw SyncFailure("Nothing is selected to sync.") }

            do {
                try DeviceFiles.preflight(base: base)
            } catch {
                forgetAccess(for: device)
                throw error
            }
            let library = try openLibrary(for: device, base: base)
            try library.prepareForWrite()
            SyncLog.record("device holds \(library.entries.count) tracks")

            var identities: [String] = []
            for song in songs { identities.append(await identity(of: song)) }
            var plan = SyncPlanner.plan(desired: identities, device: library.entries, mode: mode)

            var skipped: [(title: String, reason: String)] = []
            var addable: [Int] = []
            for index in plan.addIndices {
                if let reason = await library.rejectionReason(for: songs[index]) {
                    skipped.append((songs[index].title, reason))
                } else {
                    addable.append(index)
                }
            }
            plan.addIndices = addable
            // Songs already on the device but missing their cover are replaced, once.
            let addSet = Set(addable)
            var seenRefresh = Set<String>()
            for (index, identity) in identities.enumerated() where !addSet.contains(index) && seenRefresh.insert(identity).inserted {
                if let entry = library.entries.first(where: { $0.identity == identity }),
                   library.needsRefresh(entry, for: songs[index]),
                   !plan.remove.contains(entry) {
                    plan.remove.append(entry)
                    plan.addIndices.append(index)
                    plan.alreadyPresent -= 1
                }
            }
            SyncLog.record("plan: add \(plan.addIndices.count), remove \(plan.remove.count), already present \(plan.alreadyPresent), skipped \(skipped.count)")
            for item in skipped { print("iPodSync: skipped \(item.title): \(item.reason)") }

            // Checked before copying so a full device fails cleanly instead of half-way.
            let needed = plan.addIndices.reduce(Int64(0)) { $0 + DeviceFiles.fileSize(songs[$1].url) }
            let freed = plan.remove.reduce(Int64(0)) { $0 + DeviceFiles.fileSize(DeviceFiles.url(base: base, devicePath: $1.path)) }
            if let free = DeviceFiles.availableBytes(at: base), needed > free + freed {
                let fmt = ByteCountFormatter()
                throw SyncFailure("Not enough space on the iPod: \(fmt.string(fromByteCount: needed)) needed, \(fmt.string(fromByteCount: free + freed)) available.")
            }

            if device.generation != .classic {
                setHidden(at: base.appendingPathComponent("iPod_Control", isDirectory: true))
            }
            try DatabaseBackups.save(library.databaseFiles, key: backupKey(for: device))

            await MainActor.run {
                progress.phase = .copying
                progress.totalTracks = plan.addIndices.count
            }

            // Removals come out of the database first; their files are deleted only after the
            // new database is safely written.
            for entry in plan.remove { try library.remove(entry) }

            for (position, index) in plan.addIndices.enumerated() {
                let song = songs[index]
                await MainActor.run {
                    progress.currentTrack = song.title
                    progress.completedTracks = position
                }
                let placed = try DeviceFiles.place(song, base: base)
                copied.append(placed.url)
                SyncLog.record("copied \(song.title) -> \(placed.devicePath) (\(placed.sizeBytes) bytes)")
                _ = try await library.add(song, identity: identities[index], placed: placed)
                await MainActor.run { progress.bytesWritten += Int64(placed.sizeBytes) }
            }

            if library.supportsPlaylists {
                var requests: [PlaylistRequest] = []
                for playlist in playlists where !playlist.isSystem && !playlist.songs.isEmpty {
                    var ids: [String] = []
                    for song in playlist.songs { ids.append(await identity(of: song)) }
                    requests.append(PlaylistRequest(name: playlist.name, identities: ids))
                }
                _ = try library.writePlaylists(requests)
            }

            await setPhase(.writing)
            try library.commit()
            SyncLog.record("database written and verified (\(library.entries.count) tracks)")
            copied.removeAll()
            for entry in plan.remove { try? fm.removeItem(at: DeviceFiles.url(base: base, devicePath: entry.path)) }

            if plan.addIndices.isEmpty, plan.alreadyPresent == 0, plan.remove.isEmpty, let first = skipped.first {
                await setPhase(.failed("No tracks could be synced. \(first.title): \(first.reason)"))
                return
            }
            await setPhase(.ejecting)
            syncFilesystem(at: device.volumeURL)
            SyncLog.record("done")
            SyncLog.flush(deviceBase: base)
            await MainActor.run {
                progress.completedTracks = progress.totalTracks
                progress.phase = .done
            }
        } catch {
            // The database is written last so on failure the device still holds the old one and
            // only the files copied during this run get removed if needed. This is to avoid
            // corruption
            for url in copied { try? fm.removeItem(at: url) }
            SyncLog.record("FAILED: \(error.localizedDescription) [\(error)]")
            SyncLog.flush(deviceBase: grantedVolumeURL)
            await setPhase(.failed(error.localizedDescription))
        }
    }

    // MARK: Single-track operations

    func addTrack(_ song: Song, to device: iPodDevice) async throws {
        await sync(songs: [song], to: device, mode: .additive)
        if case let .failed(message) = progress.phase { throw SyncFailure(message) }
    }

    // `trackIndex` is the position in the list the UI shows, which is the library's entry order.
    func removeTrack(at trackIndex: Int, from device: iPodDevice) async throws {
        let base = grantedVolumeURL ?? device.volumeURL
        let library = try openLibrary(for: device, base: base)
        let entries = library.entries
        guard entries.indices.contains(trackIndex) else { return }
        try library.prepareForWrite()
        try DatabaseBackups.save(library.databaseFiles, key: backupKey(for: device))
        try library.remove(entries[trackIndex])
        try library.commit()
        // After the commit, so a failure leaves an orphaned file rather than a dangling record.
        try? FileManager.default.removeItem(at: DeviceFiles.url(base: base, devicePath: entries[trackIndex].path))
    }
}
