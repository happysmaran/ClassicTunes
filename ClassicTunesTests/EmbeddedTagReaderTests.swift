import Testing
import Foundation
import AVFoundation
@testable import ClassicTunes

private let coverA = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
private let coverB = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

private func be32(_ n: Int) -> Data {
    Data([UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
}

private func le32(_ n: Int) -> Data {
    Data([UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)])
}

// MARK: - FLAC

@MainActor
struct FLACReaderTests {

    private func block(_ type: UInt8, _ payload: Data, last: Bool = false) -> Data {
        Data([type | (last ? 0x80 : 0), UInt8((payload.count >> 16) & 0xFF), UInt8((payload.count >> 8) & 0xFF), UInt8(payload.count & 0xFF)]) + payload
    }

    private func vorbis(_ comments: [String]) -> Data {
        let vendor = "test"
        var data = le32(vendor.utf8.count) + Data(vendor.utf8) + le32(comments.count)
        for comment in comments { data.append(le32(comment.utf8.count)); data.append(Data(comment.utf8)) }
        return data
    }

    private func picture(type: Int, image: Data) -> Data {
        let mime = Data("image/png".utf8)
        return be32(type) + be32(mime.count) + mime + be32(0) + be32(1) + be32(1) + be32(0) + be32(0) + be32(image.count) + image
    }

    private func write(_ blocks: [Data], in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("test.flac")
        try (Data("fLaC".utf8) + blocks.reduce(into: Data()) { $0.append($1) } + Data(count: 500)).write(to: url)
        return url
    }

    @Test func readsEveryFieldCaseInsensitivelyAndTakesTheFirstValue() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try write([
            block(0, Data(count: 34)),
            block(4, vorbis([
                "title=Lower Case Name", "ARTIST=First Artist", "artist=Second Artist", "Album=An Album",
                "GENRE=  ", "DATE=1999-03-21", "COMPOSER=A Composer", "COMMENT=hello", "ALBUMARTIST=Various",
                "GROUPING=Suite", "TRACKNUMBER=3/12", "DISCNUMBER=2", "BPM=120", "COMPILATION=1",
                "REPLAYGAIN_TRACK_GAIN=-6 dB", "not a comment"
            ]), last: true)
        ], in: directory)

        let tags = try #require(EmbeddedTagReader.readFLAC(at: url))
        #expect(tags.title == "Lower Case Name")
        #expect(tags.artist == "First Artist")
        #expect(tags.album == "An Album")
        #expect(tags.genre == nil)                       // blank values are ignored
        #expect(tags.year == "1999-03-21")
        #expect(tags.composer == "A Composer")
        #expect(tags.comment == "hello")
        #expect(tags.albumArtist == "Various")
        #expect(tags.grouping == "Suite")
        #expect(tags.trackNumber == 3)                   // "3/12" -> 3
        #expect(tags.discNumber == 2)
        #expect(tags.bpm == 120)
        #expect(tags.compilation == true)
        #expect(tags.artworkData == nil)
    }

    @Test func prefersTheFrontCoverButFallsBackToAnyPicture() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let both = try write([
            block(0, Data(count: 34)),
            block(6, picture(type: 4, image: coverB)),
            block(6, picture(type: 3, image: coverA)),
            block(1, Data(count: 32), last: true)
        ], in: directory)
        #expect(EmbeddedTagReader.readFLAC(at: both)?.artworkData == coverA)

        let onlyBack = try write([
            block(0, Data(count: 34)),
            block(6, picture(type: 4, image: coverB), last: true)
        ], in: directory)
        #expect(EmbeddedTagReader.readFLAC(at: onlyBack)?.artworkData == coverB)
    }

    @Test func blocksAreSkippedWithoutBeingReadAndAudioIsNeverTouched() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A large unrelated block (e.g. padding or an application block) sits before the comments.
        let url = try write([
            block(0, Data(count: 34)),
            block(1, Data(count: 3_000_000)),
            block(4, vorbis(["TITLE=After The Padding"]), last: true)
        ], in: directory)
        #expect(EmbeddedTagReader.readFLAC(at: url)?.title == "After The Padding")
    }

    @Test func damagedOrForeignFilesNeverCrashAndAreHandledGracefully() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let notFLAC = directory.appendingPathComponent("x.flac")
        try Data("RIFFnope".utf8).write(to: notFLAC)
        #expect(EmbeddedTagReader.readFLAC(at: notFLAC) == nil)

        // A block that claims to be larger than the file: whatever was read so far is returned.
        let truncated = directory.appendingPathComponent("t.flac")
        try (Data("fLaC".utf8) + Data([0x04, 0xFF, 0xFF, 0xFF]) + Data(count: 10)).write(to: truncated)
        #expect(EmbeddedTagReader.readFLAC(at: truncated)?.title == nil)

        // Comments whose declared lengths run past the end of the block.
        let lying = Data(le32(4)) + Data("test".utf8) + le32(5) + le32(999) + Data("TITLE=x".utf8)
        let broken = try write([block(0, Data(count: 34)), block(4, lying, last: true)], in: directory)
        #expect(EmbeddedTagReader.readFLAC(at: broken)?.title == nil)

        #expect(EmbeddedTagReader.read(from: directory.appendingPathComponent("missing.flac")) == nil)
        #expect(EmbeddedTagReader.read(from: directory.appendingPathComponent("song.mp3")) == nil)
    }
}

// MARK: - WAV

@MainActor
struct WAVReaderTests {

    private func chunk(_ id: String, _ payload: Data) -> Data {
        var data = Data(id.utf8) + le32(payload.count) + payload
        if payload.count % 2 != 0 { data.append(0) }
        return data
    }

    private func entry(_ id: String, _ text: Data) -> Data { chunk(id, text + Data([0])) }

    private func writeWAV(_ chunks: [Data], in directory: URL) throws -> URL {
        let body = Data("WAVE".utf8) + chunks.reduce(into: Data()) { $0.append($1) }
        let url = directory.appendingPathComponent("test.wav")
        try (Data("RIFF".utf8) + le32(body.count) + body).write(to: url)
        return url
    }

    @Test func readsInfoEntriesPastOddSizedChunksAndLargeAudio() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let info = Data("INFO".utf8)
            + entry("INAM", Data("Wave Title".utf8))
            + entry("IART", Data("Wave Artist".utf8))
            + entry("IPRD", Data("Wave Album".utf8))
            + entry("IGNR", Data("Jazz".utf8))
            + entry("ICRD", Data("2001-05-06".utf8))
            + entry("ICMT", Data("a note".utf8))
            + entry("ITRK", Data("5".utf8))
            + entry("ISFT", Data("SomeEncoder".utf8))
        let url = try writeWAV([
            chunk("fmt ", Data(count: 16)),
            chunk("junk", Data(count: 7)),                    // odd size: followed by a pad byte
            chunk("data", Data(count: 2_000_000)),            // large audio chunk, skipped
            chunk("LIST", info)                               // tags after the audio, as many tools write them
        ], in: directory)

        let tags = try #require(EmbeddedTagReader.readWAV(at: url))
        #expect(tags.title == "Wave Title")
        #expect(tags.artist == "Wave Artist")
        #expect(tags.album == "Wave Album")
        #expect(tags.genre == "Jazz")
        #expect(tags.year == "2001-05-06")
        #expect(tags.comment == "a note")
        #expect(tags.trackNumber == 5)
        #expect(tags.composer == nil)
    }

    @Test func decodesWindows1252TextWhenItIsNotUTF8() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let latin1 = Data([0x43, 0x61, 0x66, 0xE9]) // "Café" in ISO-8859-1
        let url = try writeWAV([
            chunk("fmt ", Data(count: 16)),
            chunk("LIST", Data("INFO".utf8) + entry("INAM", latin1)),
            chunk("data", Data(count: 10))
        ], in: directory)
        #expect(EmbeddedTagReader.readWAV(at: url)?.title == "Café")
    }

    @Test func filesWithoutInfoOrNotRIFFAreHandled() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plain = try writeWAV([chunk("fmt ", Data(count: 16)), chunk("data", Data(count: 10))], in: directory)
        #expect(EmbeddedTagReader.readWAV(at: plain) == EmbeddedTags())

        let notWAV = directory.appendingPathComponent("x.wav")
        try Data("not a wave file at all".utf8).write(to: notWAV)
        #expect(EmbeddedTagReader.readWAV(at: notWAV) == nil)
    }
}

// MARK: - Loading songs end to end

@MainActor
struct LosslessTagRoundTripTests {

    // The scenario from the original bug: tag a real FLAC/WAV in the app, then load it back.
    @Test(arguments: [AudioFixtureFormat.flac, AudioFixtureFormat.wav])
    func tagsWrittenByTheAppAreReadBack(format: AudioFixtureFormat) async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeAudioFixture(format, to: directory.appendingPathComponent("untagged.\(format.rawValue)"))

        // A file with no tags loads with placeholders.
        let original = try await Song.load(from: url)
        #expect(original.title == "untagged")
        #expect(original.artist == "Unknown Artist")

        var edited = original
        edited.title = "A Real Title"
        edited.artist = "A Real Artist"
        edited.album = "A Real Album"
        edited.genre = "Jazz"
        edited.year = "1999"
        edited.comment = "a comment"
        edited.trackNumber = 7
        try await SongMetadataWriter.write(edited, replacing: original, to: url)

        let reloaded = try await Song.load(from: url)
        #expect(reloaded.title == "A Real Title")
        #expect(reloaded.artist == "A Real Artist")
        #expect(reloaded.album == "A Real Album")
        #expect(reloaded.genre == "Jazz")
        #expect(reloaded.year == "1999")
        #expect(reloaded.comment == "a comment")
        #expect(reloaded.trackNumber == 7)
        #expect(abs((reloaded.duration ?? 0) - 1) < 0.1)       // still playable, same length
        #expect(reloaded.id == original.id)
    }

    @Test func flacKeepsItsFullTagSetAndCoverArtThroughAnEdit() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeAudioFixture(.flac, to: directory.appendingPathComponent("song.flac"))

        var first = try await Song.load(from: url)
        let blank = first
        first.title = "Original"
        first.composer = "Composer"
        first.albumArtist = "Various"
        first.discNumber = 2
        first.bpm = 128
        first.compilation = true
        first.artworkData = coverA
        try await SongMetadataWriter.write(first, replacing: blank, to: url)

        // Everything, including the cover, is read back from the file.
        var loaded = try await Song.load(from: url)
        #expect(loaded.composer == "Composer")
        #expect(loaded.albumArtist == "Various")
        #expect(loaded.discNumber == 2)
        #expect(loaded.bpm == 128)
        #expect(loaded.compilation)
        #expect(loaded.artworkData == coverA)

        // Opening Song Info and changing only the title leaves all of that alone.
        let beforeEdit = loaded
        loaded.title = "Retitled"
        try await SongMetadataWriter.write(loaded, replacing: beforeEdit, to: url)

        let afterEdit = try await Song.load(from: url)
        #expect(afterEdit.title == "Retitled")
        #expect(afterEdit.composer == "Composer")
        #expect(afterEdit.albumArtist == "Various")
        #expect(afterEdit.discNumber == 2)
        #expect(afterEdit.bpm == 128)
        #expect(afterEdit.artworkData == coverA)
    }

    @Test func scanningALibraryShowsFLACAndWAVTagsInsteadOfFilenames() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Music", isDirectory: true)
        let flac = try writeAudioFixture(.flac, to: library.appendingPathComponent("track1.flac"))
        let wav = try writeAudioFixture(.wav, to: library.appendingPathComponent("track2.wav"))

        for url in [flac, wav] {
            let blank = try await Song.load(from: url)
            var tagged = blank
            tagged.title = "Tagged \(url.pathExtension)"
            tagged.artist = "Tagged Artist"
            try await SongMetadataWriter.write(tagged, replacing: blank, to: url)
        }

        let songs = await LibraryScanner.scan(folderURL: library, indexURL: root.appendingPathComponent("index.json"))
        #expect(songs.map(\.title).sorted() == ["Tagged flac", "Tagged wav"])
        #expect(songs.allSatisfy { $0.artist == "Tagged Artist" })
    }

    @Test func oldIndexVersionsAreDiscardedSoStalePlaceholdersAreNotServed() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // An index saved before FLAC/WAV tags were read still has "Unknown Artist" entries.
        let legacy = directory.appendingPathComponent("library.v1.json")
        try Data(#"{"version":1,"entries":{}}"#.utf8).write(to: legacy)
        #expect(LibraryIndex.load(from: legacy).entries.isEmpty)

        let current = directory.appendingPathComponent("library.v\(LibraryIndex.currentVersion).json")
        LibraryIndex().save(to: current)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(LibraryIndex.currentVersion >= 2)
    }
}
