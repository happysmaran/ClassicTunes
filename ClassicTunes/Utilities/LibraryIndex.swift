import Foundation

// A saved copy of the parsed library, so launching doesn't mean re-reading the tags of every file.
//
// Each entry remembers the file's modification date and size when it was parsed. On the next scan a
// file whose fingerprint still matches reuses its saved `Song`; only new or changed files go back
// through AVFoundation. Artwork is not stored here (songs only hold an `ArtworkStore` key).
nonisolated struct LibraryIndex: Codable {

    struct Entry: Codable {
        var modified: Double
        var size: Int
        // Inode change time. The kernel updates it on any write and, unlike `modified`, it can't be
        // set back by `touch` or `cp -p`, so an edit that preserves the modification date and size
        // is still noticed. Entries saved before this field existed decode as `nil` and are
        // re-parsed once.
        var changed: Double? = nil
        var song: Song
    }

    // Bump when `Entry`/`Song` change in a way that makes old indexes unusable.
    // (2: FLAC and WAV tags and artwork are now read, so songs saved by version 1 have stale values.)
    // (3: m4a comment, track, disc, grouping and predefined genre are now read.)
    static let currentVersion = 3

    var version = LibraryIndex.currentVersion
    // Keyed by the file's path.
    var entries: [String: Entry] = [:]

    // `~/Library/Application Support/<bundle id>/library.v1.json`.
    static var defaultURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "ClassicTunes"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("library.v\(currentVersion).json")
    }

    // Reads the index, returning an empty one if it is missing, unreadable or from another version.
    // A bad index only costs a full rescan, so it is never treated as an error.
    static func load(from url: URL?) -> LibraryIndex {
        guard let url, let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(LibraryIndex.self, from: data),
              index.version == currentVersion else { return LibraryIndex() }
        return index
    }

    func save(to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(self) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // Indexes from older versions are never read again; don't leave them behind.
        for older in 1..<Self.currentVersion {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("library.v\(older).json"))
        }
    }
}

// Finds the audio files under a folder and turns them into `Song`s, reusing the saved index.
nonisolated enum LibraryScanner {

    static let allowedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac"]

    // How many files are parsed at the same time. Each parse opens an AVURLAsset, so an unbounded
    // task group on a large library would try to open thousands of files at once.
    static let maxConcurrentLoads = 8

    // An audio file found on disk along with the values that decide whether its saved entry is current.
    struct File {
        let url: URL
        let modified: Double
        let size: Int
        let changed: Double
        let created: Date?
    }

    // Scans `folderURL` recursively.
    //
    // - Parameters:
    //   - folderURL: The music folder (security-scoped access must already be active).
    //   - indexURL: Where the index is read from and written to; `nil` disables the index.
    // - Returns: The library's songs, in directory-enumeration order.
    static func scan(folderURL: URL, indexURL: URL? = LibraryIndex.defaultURL) async -> [Song] {
        // Directory enumeration and index decoding are synchronous and can take a while on a big
        // library, so keep them off the caller's (usually the main) actor.
        let (files, index) = await Task.detached(priority: .userInitiated) {
            (enumerateAudioFiles(in: folderURL), LibraryIndex.load(from: indexURL))
        }.value

        var results = [Song?](repeating: nil, count: files.count)
        var stale: [Int] = []
        for (position, file) in files.enumerated() {
            if let entry = index.entries[file.url.path], isCurrent(entry, for: file) {
                results[position] = entry.song
            } else {
                stale.append(position)
            }
        }

        // Parse only the new or changed files, a few at a time.
        await withTaskGroup(of: (Int, Song?).self) { group in
            var next = 0
            func launchNext() {
                guard next < stale.count else { return }
                let position = stale[next]
                let file = files[position]
                next += 1
                group.addTask(priority: .userInitiated) {
                    (position, try? await Song.load(from: file.url, dateAdded: file.created))
                }
            }
            for _ in 0..<min(maxConcurrentLoads, stale.count) { launchNext() }
            while let (position, song) = await group.next() {
                results[position] = song
                launchNext()
            }
        }

        let songs = results.compactMap { $0 }

        // Save the refreshed index (dropping files that no longer exist), unless nothing changed.
        // If the folder itself is gone (e.g. an unmounted drive) the "no files" result isn't real, so
        // keep the existing index instead of emptying it.
        let unchanged = stale.isEmpty && index.entries.count == files.count
        let folderIsReachable = FileManager.default.fileExists(atPath: folderURL.path)
        if !unchanged && folderIsReachable {
            var updated = LibraryIndex()
            for (position, file) in files.enumerated() {
                guard let song = results[position] else { continue }
                updated.entries[file.url.path] = LibraryIndex.Entry(modified: file.modified, size: file.size, changed: file.changed, song: song)
            }
            await Task.detached(priority: .utility) { updated.save(to: indexURL) }.value
        }
        return songs
    }

    // A saved entry is reused only if the file is unchanged and its artwork can still be loaded
    // (the artwork cache may have been cleared since the entry was saved).
    static func isCurrent(_ entry: LibraryIndex.Entry, for file: File) -> Bool {
        guard entry.modified == file.modified, entry.size == file.size, entry.changed == file.changed else { return false }
        if let key = entry.song.artworkKey { return ArtworkStore.shared.contains(key) }
        return true
    }

    static func enumerateAudioFiles(in folderURL: URL) -> [File] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .attributeModificationDateKey, .fileSizeKey, .creationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            print("Could not create enumerator")
            return []
        }

        var files: [File] = []
        while let url = enumerator.nextObject() as? URL {
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            files.append(File(
                url: url,
                modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                size: values?.fileSize ?? 0,
                changed: values?.attributeModificationDate?.timeIntervalSince1970 ?? 0,
                created: values?.creationDate
            ))
        }
        return files
    }
}
