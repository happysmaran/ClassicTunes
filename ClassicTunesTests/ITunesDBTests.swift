import Foundation
import Testing
@testable import ClassicTunes

// Fixtures are read relative to this file so the test target needs no resource-bundle setup.
private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).b64")
    let text = try String(contentsOf: url, encoding: .ascii).trimmingCharacters(in: .whitespacesAndNewlines)
    return try #require(Data(base64Encoded: text))
}

private func sampleTrack(_ title: String, number: UInt32 = 1) -> ClassicTrackInput {
    ClassicTrackInput(
        title: title, artist: "Artist", album: "Album", genre: "Rock",
        trackNumber: number, durationMS: 180_000, sizeBytes: 4_000_000,
        bitrateKbps: 192, sampleRateHz: 44_100, encoding: .mp3,
        location: ":iPod_Control:Music:F00:\(title.prefix(4).uppercased()).mp3"
    )
}

struct ITunesDBTests {

    @Test func emptyFixtureRoundTripsByteForByte() throws {
        let original = try fixture("original-empty")
        let document = try ITunesDBDocument(data: original)
        #expect(document.serialized() == original)
        #expect(document.tracks().isEmpty)
        #expect(document.hashingScheme == 0)
    }

    @Test func sixtyTrackFixtureRoundTripsByteForByte() throws {
        let original = try fixture("captured-album-index-36")
        let document = try ITunesDBDocument(data: original)
        #expect(document.serialized() == original)
        #expect(document.tracks().count == 60)
        #expect(document.playlists().first(where: \.isMaster)?.trackIDs.count == 60)
    }

    // An index type with no verified ordering rule would silently go stale, so it blocks edits.
    @Test func refusesToEditDatabasesWithUnsupportedIndexType() throws {
        let document = try ITunesDBDocument(data: try fixture("captured-album-index-36"))
        let index = try #require(document.indexMHODs().first)
        index.body.writeLE(UInt32(0x1D), at: 0)
        #expect(throws: ITunesDBError.self) { try document.addTrack(sampleTrack("Blocked")) }
    }

    // Albums must stay contiguous in sort 36 and every master position must appear exactly once.
    @Test func rebuiltAlbumIndexCoversEveryTrackAndKeepsAlbumsContiguous() throws {
        let document = try ITunesDBDocument(data: try fixture("captured-album-index-36"))
        _ = try document.addTrack(sampleTrack("New one"))
        _ = try document.addTrack(sampleTrack("New two", number: 2))
        try document.finalizeForWrite()

        let reparsed = try ITunesDBDocument(data: document.serialized())
        let index = try #require(reparsed.indexMHODs().first)
        #expect(index.body.readLE(UInt32.self, at: 4) == 62)
        let positions = (0..<62).map { index.body.readLE(UInt32.self, at: 48 + 4 * $0) ?? .max }
        #expect(Set(positions) == Set((0..<62).map(UInt32.init)))

        let master = try #require(reparsed.masterPlaylist())
        let trackIDs = master.children.filter { $0.magic == "mhip" }.map { $0.header.readLE(UInt32.self, at: 0x18) ?? 0 }
        let tracksByID = Dictionary(uniqueKeysWithValues: (reparsed.dataset(1)?.children ?? []).map { ($0.header.readLE(UInt32.self, at: 0x10) ?? 0, $0) })
        let albumIDs = positions.map { tracksByID[trackIDs[Int($0)]]?.header.readLE(UInt32.self, at: 0x120) ?? 0 }
        var seen = Set<UInt32>()
        var previous: UInt32?
        for id in albumIDs where id != previous {
            #expect(!seen.contains(id), "album \(id) is split in the index")
            seen.insert(id)
            previous = id
        }
    }

    // Both new tracks share an album and artist, so they must share one album record.
    @Test func tracksOfOneAlbumShareAnAlbumRecord() throws {
        let document = try ITunesDBDocument(data: try fixture("captured-album-index-36"))
        let before = document.dataset(4)?.children.count ?? 0
        _ = try document.addTrack(sampleTrack("One"))
        _ = try document.addTrack(sampleTrack("Two", number: 2))
        #expect((document.dataset(4)?.children.count ?? 0) == before + 1)
    }

    @Test func refusesToEditSignedDatabases() throws {
        var bytes = try fixture("original-empty")
        bytes.writeLE(UInt16(1), at: 0x30)
        let document = try ITunesDBDocument(data: bytes)
        #expect(throws: ITunesDBError.self) { try document.addTrack(sampleTrack("Signed")) }
    }

    @Test func addedTrackSurvivesSerializeAndReparse() throws {
        let document = try ITunesDBDocument(data: try fixture("original-empty"))
        let id = try document.addTrack(sampleTrack("First"))

        let reparsed = try ITunesDBDocument(data: document.serialized())
        let tracks = reparsed.tracks()
        #expect(tracks.count == 1)
        #expect(tracks[0].id == id)
        #expect(tracks[0].title == "First")
        #expect(tracks[0].artist == "Artist")
        #expect(tracks[0].devicePath == "/iPod_Control/Music/F00/FIRS.mp3")
        #expect(tracks[0].durationMS == 180_000)
        #expect(reparsed.playlists().first(where: \.isMaster)?.trackIDs == [id])
        // Version 79 selects the largest header layout.
        #expect(reparsed.dataset(1)?.children.first?.header.count == 0x270)
        // A second round trip must not change a single byte.
        #expect(reparsed.serialized() == document.serialized())
    }

    @Test func removingATrackUpdatesPlaylistsAndPositions() throws {
        let document = try ITunesDBDocument(data: try fixture("original-empty"))
        let first = try document.addTrack(sampleTrack("First"))
        let second = try document.addTrack(sampleTrack("Second", number: 2))
        try document.upsertPlaylist(named: "Mix", trackIDs: [first, second])

        let removed = try document.removeTrack(id: first)
        #expect(removed?.title == "First")

        let reparsed = try ITunesDBDocument(data: document.serialized())
        #expect(reparsed.tracks().map(\.id) == [second])
        for playlist in reparsed.playlists() {
            #expect(playlist.trackIDs == [second])
        }
        let master = try #require(reparsed.masterPlaylist())
        let item = try #require(master.children.first { $0.magic == "mhip" })
        let position = try #require(item.children.first)
        #expect(position.body.readLE(UInt32.self, at: 0) == 0)
    }

    @Test func upsertReplacesSameNamedPlaylistAndKeepsOthers() throws {
        let document = try ITunesDBDocument(data: try fixture("original-empty"))
        let a = try document.addTrack(sampleTrack("Alpha"))
        let b = try document.addTrack(sampleTrack("Beta", number: 2))

        try document.upsertPlaylist(named: "Road Trip", trackIDs: [a, b])
        try document.upsertPlaylist(named: "Road Trip", trackIDs: [b])
        try document.upsertPlaylist(named: "Other", trackIDs: [a])

        let reparsed = try ITunesDBDocument(data: document.serialized())
        let user = reparsed.playlists().filter { !$0.isMaster }
        #expect(user.count == 2)
        #expect(user.first { $0.name == "Road Trip" }?.trackIDs == [b])
        #expect(user.first { $0.name == "Other" }?.trackIDs == [a])
        #expect(reparsed.playlists().first(where: \.isMaster)?.trackIDs == [a, b])
    }

    @Test func playlistItemIDsAreUniqueAcrossTheDatabase() throws {
        let document = try ITunesDBDocument(data: try fixture("original-empty"))
        let a = try document.addTrack(sampleTrack("Alpha"))
        let b = try document.addTrack(sampleTrack("Beta", number: 2))
        try document.upsertPlaylist(named: "Mix", trackIDs: [a, b])

        let container = try #require(document.dataset(2))
        let itemIDs = container.children
            .flatMap { $0.children.filter { $0.magic == "mhip" } }
            .compactMap { $0.header.readLE(UInt32.self, at: 0x14) }
        #expect(itemIDs.count == 4)
        #expect(Set(itemIDs).count == itemIDs.count)
    }

    @Test func truncatedDatabaseThrowsInsteadOfCrashing() throws {
        let original = try fixture("original-empty")
        #expect(throws: ITunesDBError.self) {
            _ = try ITunesDBDocument(data: original.prefix(original.count / 2))
        }
    }

    // A database newer than the iPod's firmware is read as empty, so an empty one is recreated
    // at the firmware's version with the browse lists a master playlist needs.
    @Test func emptyTemplateAcceptsTracksAndKeepsItsVersion() throws {
        let document = try ITunesDBTemplate.emptyDatabase(version: 0x13)
        #expect(document.version == 0x13)
        #expect(document.sortTypes().map(\.type) == [0x03, 0x05, 0x04, 0x07, 0x12])
        _ = try document.addTrack(sampleTrack("First"))
        _ = try document.addTrack(sampleTrack("Second", number: 2))
        try document.finalizeForWrite()

        let reparsed = try ITunesDBDocument(data: document.serialized())
        #expect(reparsed.version == 0x13)
        #expect(reparsed.tracks().count == 2)
        #expect(reparsed.sortTypes().allSatisfy { $0.count == 2 })
        #expect(reparsed.jumpTableTypes().count == 10)   // five per master playlist
        #expect(reparsed.masterPlaylists().count == 2)
        let header = try #require(reparsed.dataset(1)?.children.first?.header.count)
        #expect(header == 0x148)
    }

    // Newer firmware reads dataset 3's master playlist, so a track listed only in dataset 2 is
    // invisible on the iPod. A database written that way is repaired on the next write.
    @Test func finalizeRepairsAnEmptyDatasetThreeMaster() throws {
        let document = try ITunesDBTemplate.emptyDatabase(version: 0x13)
        _ = try document.addTrack(sampleTrack("First"))
        let masters = document.masterPlaylists()
        #expect(masters.count == 2)
        masters[1].children.removeAll { $0.magic == "mhip" }

        try document.finalizeForWrite()
        let reparsed = try ITunesDBDocument(data: document.serialized())
        try reparsed.validate()
        let items = reparsed.masterPlaylists().map { $0.children.filter { $0.magic == "mhip" }.count }
        #expect(items == [1, 1])
    }

    @Test func playlistsAreWrittenToBothDatasets() throws {
        let document = try ITunesDBTemplate.emptyDatabase(version: 0x13)
        let id = try document.addTrack(sampleTrack("First"))
        try document.upsertPlaylist(named: "Mix", trackIDs: [id])
        for type: UInt32 in [2, 3] {
            let mixes = (document.dataset(type)?.children ?? []).filter { $0.magic == "mhyp" && $0.children.contains { $0.magic == "mhip" } && ($0.header.readLE(UInt8.self, at: 0x14) ?? 1) == 0 }
            #expect(mixes.count == 1)
        }
    }
}
