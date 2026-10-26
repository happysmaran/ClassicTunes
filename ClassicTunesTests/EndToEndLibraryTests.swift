import Testing
import Foundation
import AVFoundation
import Combine
@testable import ClassicTunes

// Automated versions of the checks that otherwise have to be done by hand with a real library:
// real audio files on disk, scanned, edited, rescanned.

private let coverPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

@MainActor
struct EndToEndLibraryTests {

    // A music folder with an album per sub-folder, one file of each supported test format.
    private func makeLibrary() throws -> (root: URL, library: URL, indexURL: URL) {
        let root = try makeScratchDirectory("Library")
        let library = root.appendingPathComponent("Music", isDirectory: true)
        try writeAudioFixture(.m4a, to: library.appendingPathComponent("Album A/01 First.m4a"))
        try writeAudioFixture(.wav, to: library.appendingPathComponent("Album A/02 Second.wav"))
        try writeAudioFixture(.flac, to: library.appendingPathComponent("Album B/03 Third.flac"))
        return (root, library, root.appendingPathComponent("library-index.json"))
    }

    @Test func firstScanFindsEverythingAndRecordsIt() async throws {
        let (root, library, indexURL) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let songs = await LibraryScanner.scan(folderURL: library, indexURL: indexURL)

        #expect(songs.map(\.title).sorted() == ["01 First", "02 Second", "03 Third"])
        #expect(songs.allSatisfy { abs(($0.duration ?? 0) - 1) < 0.1 })
        #expect(songs.allSatisfy { $0.dateAdded != nil })
        #expect(songs.allSatisfy { $0.id == Song.stableID(for: $0.url) })
        #expect(LibraryIndex.load(from: indexURL).entries.count == 3)
    }

    @Test func rescanningAnUnchangedLibraryReusesTheIndexAndKeepsIdentities() async throws {
        let (root, library, indexURL) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = await LibraryScanner.scan(folderURL: library, indexURL: indexURL)

        // Mark one saved entry. If the second scan returns the mark, that song came from the
        // index rather than being parsed from the file again.
        var index = LibraryIndex.load(from: indexURL)
        let key = try #require(index.entries.keys.first { $0.hasSuffix("01 First.m4a") })
        index.entries[key]?.song.title = "FROM THE INDEX"
        index.save(to: indexURL)

        let second = await LibraryScanner.scan(folderURL: library, indexURL: indexURL)
        #expect(second.map(\.title).contains("FROM THE INDEX"))
        #expect(second.count == first.count)
        #expect(Set(second.map(\.id)) == Set(first.map(\.id)))
    }

    @Test func editedAddedAndRemovedFilesAreAllPickedUp() async throws {
        let (root, library, indexURL) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = await LibraryScanner.scan(folderURL: library, indexURL: indexURL)
        let untouched = try #require(first.first { $0.title == "03 Third" })

        // Mark every saved entry so we can tell which songs were re-read from disk.
        var index = LibraryIndex.load(from: indexURL)
        for key in index.entries.keys { index.entries[key]?.song.comment = "STALE" }
        index.save(to: indexURL)

        // Edit one file through the app's own writer (changes its content and timestamps),
        // add a new file, remove another.
        let editedURL = library.appendingPathComponent("Album A/01 First.m4a")
        let original = try #require(first.first { $0.url == editedURL })
        var edited = original
        edited.title = "Renamed In The App"
        edited.composer = "A. Composer"
        try await SongMetadataWriter.write(edited, replacing: original, to: editedURL)
        try writeAudioFixture(.m4a, to: library.appendingPathComponent("Album B/04 Fourth.m4a"))
        try FileManager.default.removeItem(at: library.appendingPathComponent("Album A/02 Second.wav"))

        let second = await LibraryScanner.scan(folderURL: library, indexURL: indexURL)

        #expect(second.count == 3)
        #expect(!second.contains { $0.title == "02 Second" })                       // removed
        #expect(second.contains { $0.title == "04 Fourth" })                        // added
        let reread = try #require(second.first { $0.url == editedURL })
        #expect(reread.title == "Renamed In The App")                               // edit noticed...
        #expect(reread.composer == "A. Composer")
        #expect(reread.comment != "STALE")                                          // ...by re-reading the file
        #expect(reread.id == original.id)                                           // same identity as before
        let notReread = try #require(second.first { $0.url == untouched.url })
        #expect(notReread.comment == "STALE")                                       // unchanged file came from the index

        let saved = LibraryIndex.load(from: indexURL)
        #expect(Set(saved.entries.keys) == Set(second.map(\.url.path)))
    }

    @Test func artworkIsSharedAcrossSongsAndSurvivesRescans() async throws {
        let (root, library, indexURL) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let a = library.appendingPathComponent("Album A/01 First.m4a")
        let b = library.appendingPathComponent("Album A/05 Fifth.m4a")
        try writeAudioFixture(.m4a, to: b)
        try await retag(a, with: [pngTag(coverPNG)])
        try await retag(b, with: [pngTag(coverPNG)])

        let first = await LibraryScanner.scan(folderURL: library, indexURL: indexURL)
        let withArt = first.filter { $0.url == a || $0.url == b }
        #expect(withArt.count == 2)
        let key = try #require(withArt.first?.artworkKey)
        #expect(withArt.allSatisfy { $0.artworkKey == key })                         // one image, one key
        #expect(ArtworkStore.shared.data(for: key) == coverPNG)                      // the original bytes

        // The index stores only the key, never the image.
        let indexText = try String(contentsOf: indexURL, encoding: .utf8)
        #expect(indexText.contains(key))
        #expect(indexText.count < 20_000)

        let second = await LibraryScanner.scan(folderURL: library, indexURL: indexURL)
        #expect(second.filter { $0.artworkKey == key }.count == 2)
        #expect(Set(second.map(\.id)) == Set(first.map(\.id)))
    }

    @Test func playCountsAndHistoryStayWithTheFileAcrossRescans() async throws {
        let (root, library, indexURL) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let defaults = UserDefaults.standard
        let keys = [playCountKey, playHistoryKey, lastPlayedKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }

        let first = await LibraryScanner.scan(folderURL: library, indexURL: indexURL)
        let played = try #require(first.first { $0.title == "01 First" })
        incrementPlayCount(for: played)
        incrementPlayCount(for: played)

        // A "relaunch": throw the index away so every song is rebuilt from its file.
        try? FileManager.default.removeItem(at: indexURL)
        let relaunched = await LibraryScanner.scan(folderURL: library, indexURL: indexURL)
        let sameSong = try #require(relaunched.first { $0.title == "01 First" })

        #expect(getPlayCount(for: sameSong) == 2)
        #expect(getAllPlayCounts()[sameSong.id] == 2)
        #expect(generateRecentlyPlayedPlaylist(from: relaunched).songs.map(\.title) == ["01 First"])
        #expect(generateTopPlayedPlaylist(from: relaunched, maxCount: 1).songs.map(\.title) == ["01 First"])
    }

    @Test func playlistsSurviveARelaunchAndTheLibraryRescan() async throws {
        let (root, library, indexURL) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let songs = await LibraryScanner.scan(folderURL: library, indexURL: indexURL)
        let chosen = Array(songs.prefix(2))

        let storeDirectory = root.appendingPathComponent("PlaylistData", isDirectory: true)
        PlaylistStore(directory: storeDirectory).save([Playlist(name: "Mix", songs: chosen)])

        // New store + fresh scan, as after a relaunch.
        let loaded = PlaylistStore(directory: storeDirectory).load()
        let rescanned = await LibraryScanner.scan(folderURL: library, indexURL: indexURL)

        #expect(loaded.count == 1)
        #expect(Set(loaded[0].songs.map(\.id)) == Set(chosen.map(\.id)))
        // Every song in the saved playlist matches a song in the rescanned library by ID.
        let libraryIDs = Set(rescanned.map(\.id))
        #expect(loaded[0].songs.allSatisfy { libraryIDs.contains($0.id) })
    }
}

// MARK: - Playback state

@MainActor
struct PlaybackStateTests {

    // Waits (without blocking the main actor) until `condition` holds, or gives up.
    private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test func positionTicksDoNotInvalidateViewsObservingTheEngine() {
        let engine = PlayerEngine.shared
        var engineChanges = 0
        var clockChanges = 0
        let engineToken = engine.objectWillChange.sink { _ in engineChanges += 1 }
        let clockToken = engine.clock.objectWillChange.sink { _ in clockChanges += 1 }
        defer { engineToken.cancel(); clockToken.cancel() }

        let before = engine.playbackPosition
        for step in 1...50 { engine.playbackPosition = Double(step) / 100 }
        defer { engine.playbackPosition = before }

        // A view observing the engine (like ContentView) is not redrawn by position ticks...
        #expect(engineChanges == 0)
        // ...while the views that show the position (observing the clock) are.
        #expect(clockChanges == 50)
        #expect(engine.clock.position == engine.playbackPosition)
    }

    @Test func playAndPauseStillNotifyObservers() async throws {
        let directory = try makeScratchDirectory("Playback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeAudioFixture(.m4a, to: directory.appendingPathComponent("silence.m4a"), seconds: 5)
        let song = Song(url: url, title: "Silence", artist: "A", album: "B", genre: "G", duration: 5)

        let engine = PlayerEngine.shared
        let originalVolume = engine.volume
        engine.volume = 0
        defer {
            engine.pause()
            engine.volume = originalVolume
        }

        var engineChanges = 0
        let token = engine.objectWillChange.sink { _ in engineChanges += 1 }
        defer { token.cancel() }

        engine.playSong(song)
        #expect(await eventually { (engine.player?.rate ?? 0) != 0 })

        // Pausing flips the player's rate. Views that read it must be told, since position ticks
        // no longer do that for them.
        let revisionBeforePause = engine.playStateRevision
        engineChanges = 0
        engine.pause()
        #expect(await eventually { engine.playStateRevision != revisionBeforePause })
        #expect(engine.player?.rate == 0)
        #expect(engineChanges > 0)

        let revisionBeforePlay = engine.playStateRevision
        engine.play()
        #expect(await eventually { engine.playStateRevision != revisionBeforePlay })
        #expect((engine.player?.rate ?? 0) != 0)
    }
}
