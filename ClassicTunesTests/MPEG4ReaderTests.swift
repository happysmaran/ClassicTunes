import Testing
import Foundation
import AVFoundation
@testable import ClassicTunes

private let cover = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

@MainActor
struct MPEG4ReaderTests {

    private func makeM4A(in directory: URL, tags: [AVMetadataItem] = []) async throws -> URL {
        let url = try writeAudioFixture(.m4a, to: directory.appendingPathComponent("song.m4a"))
        if !tags.isEmpty { try await retag(url, with: tags) }
        return url
    }

    // The atoms in the file, as stored.
    private func atoms(in url: URL) async throws -> [(id: String, dataType: String?, bytes: [UInt8]?, text: String?)] {
        var result: [(id: String, dataType: String?, bytes: [UInt8]?, text: String?)] = []
        for item in try await AVURLAsset(url: url).load(.metadata) {
            let value = try await item.load(.value)
            result.append((
                item.identifier?.rawValue ?? "",
                item.dataType,
                (value as? Data).map { [UInt8]($0) },
                value as? String
            ))
        }
        return result
    }

    @Test func everyFieldWrittenByTheAppIsReadBack() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await makeM4A(in: directory)

        let blank = try await Song.load(from: url)
        var edited = blank
        edited.title = "Title"
        edited.artist = "Artist"
        edited.album = "Album"
        edited.genre = "Rock"
        edited.year = "1999"
        edited.composer = "Composer"
        edited.comment = "A comment"
        edited.albumArtist = "Album Artist"
        edited.grouping = "Grouping"
        edited.trackNumber = 3
        edited.discNumber = 2
        edited.bpm = 120
        edited.compilation = true
        edited.artworkData = cover
        try await SongMetadataWriter.write(edited, replacing: blank, to: url)

        let loaded = try await Song.load(from: url)
        #expect(loaded.title == "Title")
        #expect(loaded.artist == "Artist")
        #expect(loaded.album == "Album")
        #expect(loaded.genre == "Rock")
        #expect(loaded.year == "1999")
        #expect(loaded.composer == "Composer")
        #expect(loaded.comment == "A comment")
        #expect(loaded.albumArtist == "Album Artist")
        #expect(loaded.grouping == "Grouping")
        #expect(loaded.trackNumber == 3)
        #expect(loaded.discNumber == 2)
        #expect(loaded.bpm == 120)
        #expect(loaded.compilation)
        #expect(loaded.artworkData == cover)
    }

    @Test func tracksAndDiscsAreStoredTheWayAppleStoresThem() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await makeM4A(in: directory)

        let blank = try await Song.load(from: url)
        var edited = blank
        edited.trackNumber = 3
        edited.discNumber = 2
        edited.grouping = "Suite"
        try await SongMetadataWriter.write(edited, replacing: blank, to: url)

        let stored = try await atoms(in: url)
        let track = try #require(stored.first { $0.id == "itsk/trkn" })
        let disc = try #require(stored.first { $0.id == "itsk/disk" })
        // A binary (reserved, number, total, ...) record, not a plain integer: other taggers
        // would read a plain integer as track 0.
        #expect(track.dataType == "com.apple.metadata.datatype.raw-data")
        #expect(track.bytes == [0, 0, 0, 3, 0, 0, 0, 0])
        #expect(disc.bytes == [0, 0, 0, 2, 0, 0])

        // Grouping uses ©grp, as Apple's Music app does, not AVFoundation's own `grup`.
        #expect(stored.first { $0.id == "itsk/%A9grp" }?.text == "Suite")
        #expect(!stored.contains { $0.id == "itsk/grup" })
    }

    @Test func atomsWrittenByAppleAppsAreRead() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await makeM4A(in: directory, tags: [
            stringTag(.iTunesMetadataSongName, "Apple Title"),
            rawTag(.iTunesMetadataTrackNumber, [0, 0, 0, 5, 0, 12, 0, 0]),      // track 5 of 12
            rawTag(.iTunesMetadataDiscNumber, [0, 0, 0, 2, 0, 3]),              // disc 2 of 3
            stringTag(.iTunesMetadataUserComment, "Ripped with care"),
            stringTag(AVMetadataIdentifier(rawValue: "itsk/%A9grp"), "Movement I"),
            rawTag(.iTunesMetadataPredefinedGenre, [0, 18])                     // ID3 genre 17 + 1 = Rock
        ])

        let song = try await Song.load(from: url)
        #expect(song.title == "Apple Title")
        #expect(song.trackNumber == 5)
        #expect(song.discNumber == 2)
        #expect(song.comment == "Ripped with care")
        #expect(song.grouping == "Movement I")
        #expect(song.genre == "Rock")
    }

    @Test func aGenreNameBeatsAPredefinedGenreInEitherOrder() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await makeM4A(in: directory, tags: [
            rawTag(.iTunesMetadataPredefinedGenre, [0, 18]),
            stringTag(.iTunesMetadataUserGenre, "Shoegaze")
        ])
        #expect(try await Song.load(from: url).genre == "Shoegaze")

        let other = directory.appendingPathComponent("other", isDirectory: true)
        let reversed = try await makeM4A(in: other, tags: [
            stringTag(.iTunesMetadataUserGenre, "Shoegaze"),
            rawTag(.iTunesMetadataPredefinedGenre, [0, 18])
        ])
        #expect(try await Song.load(from: reversed).genre == "Shoegaze")
    }

    @Test func plainIntegerTrackNumbersFromOlderVersionsAreStillRead() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await makeM4A(in: directory, tags: [
            numberTag(.iTunesMetadataTrackNumber, 7),
            numberTag(.iTunesMetadataDiscNumber, 2)
        ])
        let song = try await Song.load(from: url)
        #expect(song.trackNumber == 7)
        #expect(song.discNumber == 2)
    }

    @Test func retitlingKeepsTheOtherTagsIncludingOnesTheAppDidNotWrite() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await makeM4A(in: directory, tags: [
            stringTag(.iTunesMetadataSongName, "Old"),
            rawTag(.iTunesMetadataTrackNumber, [0, 0, 0, 5, 0, 12, 0, 0]),
            stringTag(.iTunesMetadataUserComment, "keep me"),
            stringTag(.iTunesMetadataLyrics, "la la la")
        ])

        let original = try await Song.load(from: url)
        var edited = original
        edited.title = "New"
        try await SongMetadataWriter.write(edited, replacing: original, to: url)

        let song = try await Song.load(from: url)
        #expect(song.title == "New")
        #expect(song.trackNumber == 5)
        #expect(song.comment == "keep me")
        let stored = try await atoms(in: url)
        #expect(stored.first { $0.id == "itsk/%A9lyr" }?.text == "la la la")
        // The untouched track record is carried over byte-for-byte, including its total.
        #expect(stored.first { $0.id == "itsk/trkn" }?.bytes == [0, 0, 0, 5, 0, 12, 0, 0])
    }
}
