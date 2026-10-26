import Testing
import Foundation
import AVFoundation
@testable import ClassicTunes

// MARK: - Helpers

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SongMetadataWriterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeSong(at url: URL, title: String = "Old Title", artist: String = "Real Artist", album: String = "Album") -> Song {
    Song(url: url, title: title, artist: artist, album: album, genre: "Rock")
}

// A 1x1 PNG, so artwork edits have real image bytes to work with.
private let pngA = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
private let pngB = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

// Bytes standing in for encoded audio; the writer must never change them.
private func fakeAudio(_ count: Int = 20_000) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
}

private func be32(_ n: Int) -> Data {
    Data([UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
}

private func le32(_ n: Int) -> Data {
    Data([UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)])
}

private func syncsafe(_ n: Int) -> Data {
    Data([UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)])
}

// MARK: - Which fields count as changed

@MainActor
struct ChangedFieldsTests {

    @Test func identicalSongsHaveNoChangedFields() {
        let song = makeSong(at: URL(fileURLWithPath: "/tmp/a.mp3"))
        #expect(SongMetadataWriter.changedFields(from: song, to: song).isEmpty)
    }

    @Test func onlyEditedFieldsAreReported() {
        let original = makeSong(at: URL(fileURLWithPath: "/tmp/a.mp3"))
        var edited = original
        edited.title = "New"
        edited.comment = "hello"
        edited.compilation = true
        edited.artworkData = pngA
        #expect(SongMetadataWriter.changedFields(from: original, to: edited) == [.title, .comment, .compilation, .artwork])
    }

    @Test func withoutAnOriginalEverythingIsWritten() {
        let song = makeSong(at: URL(fileURLWithPath: "/tmp/a.mp3"))
        #expect(SongMetadataWriter.changedFields(from: nil, to: song) == Set(SongTagField.allCases))
    }
}

// MARK: - MP3 / ID3v2

@MainActor
struct ID3WriterTests {

    private func id3Frame(_ id: String, _ payload: Data, version: UInt8) -> Data {
        var frame = Data(id.utf8)
        frame.append(version == 4 ? syncsafe(payload.count) : be32(payload.count))
        frame.append(contentsOf: [0, 0])
        frame.append(payload)
        return frame
    }

    // ISO-8859-1 text frame payload.
    private func latin1(_ text: String) -> Data { Data([0]) + Data(text.utf8) }

    private func commentPayload(description: String, text: String) -> Data {
        Data([0]) + Data("eng".utf8) + Data(description.utf8) + Data([0]) + Data(text.utf8)
    }

    private func pictureFramePayload(type: UInt8, image: Data) -> Data {
        Data([0]) + Data("image/png".utf8) + Data([0, type, 0]) + image
    }

    // The frames of a tag as written by "another program": things this app never touches next to
    // things it manages.
    private struct Fixture {
        let url: URL
        let audio: Data
        let frames: [String: Data]   // raw frames by a label, for later comparison
    }

    private func makeMP3(version: UInt8, flags: UInt8 = 0, extendedHeader: Data = Data(), footer: Bool = false, in directory: URL) throws -> Fixture {
        var labelled: [(String, String, Data)] = [
            ("title", "TIT2", latin1("Old Title")),
            ("artist", "TPE1", latin1("Real Artist")),
            ("lyrics", "USLT", Data([0]) + Data("eng".utf8) + Data([0]) + Data("la la la".utf8)),
            ("rating", "POPM", Data("someone@example.com".utf8) + Data([0, 196, 0, 0, 0, 5])),
            ("replaygain", "TXXX", latin1("REPLAYGAIN_TRACK_GAIN") .dropLast(0) + Data([0]) + Data("-6.5 dB".utf8)),
            ("soundcheck", "COMM", commentPayload(description: "iTunNORM", text: " 00000A2B 00000A2B")),
            ("comment", "COMM", commentPayload(description: "", text: "old comment")),
            ("front", "APIC", pictureFramePayload(type: 3, image: pngA)),
            ("back", "APIC", pictureFramePayload(type: 4, image: pngB)),
            ("date", "TDAT", latin1("1503")),
            ("year", version == 4 ? "TDRC" : "TYER", latin1("1999"))
        ]
        if version == 4 { labelled.removeAll { $0.1 == "TDAT" } } // TDAT doesn't exist in v2.4

        var frames: [String: Data] = [:]
        var body = extendedHeader
        for (label, id, payload) in labelled {
            let frame = id3Frame(id, payload, version: version)
            frames[label] = frame
            body.append(frame)
        }
        body.append(Data(count: 200)) // padding

        var tag = Data([0x49, 0x44, 0x33, version, 0, flags])
        tag.append(syncsafe(body.count))
        tag.append(body)

        var file = tag
        let audio = fakeAudio()
        if footer {
            // A v2.4 footer is a copy of the header with "3DI" as its marker.
            file.append(Data([0x33, 0x44, 0x49, version, 0, flags]) + syncsafe(body.count))
        }
        file.append(audio)

        let url = directory.appendingPathComponent("song.mp3")
        try file.write(to: url)
        return Fixture(url: url, audio: audio, frames: frames)
    }

    private func readTag(_ url: URL) throws -> SongMetadataWriter.ID3Tag {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try #require(try SongMetadataWriter.readID3Tag(from: handle))
    }

    private func utf16Text(_ payload: Data) -> String {
        String(data: payload.dropFirst(3), encoding: .utf16LittleEndian) ?? ""
    }

    @Test(arguments: [UInt8(3), UInt8(4)])
    func editingKeepsEverythingTheAppDoesNotManage(version: UInt8) async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeMP3(version: version, in: directory)

        let original = makeSong(at: fixture.url)
        var edited = original
        edited.title = "New Title"
        edited.comment = "new comment"
        edited.year = "2005"
        edited.artworkData = pngB

        try await SongMetadataWriter.write(edited, replacing: original, to: fixture.url)

        let tag = try readTag(fixture.url)
        #expect(tag.majorVersion == version)

        // The audio is byte-for-byte what it was.
        let written = try Data(contentsOf: fixture.url)
        #expect(written.suffix(fixture.audio.count) == fixture.audio)
        #expect(written.count == tag.audioStart + fixture.audio.count)

        func frames(_ id: String) -> [SongMetadataWriter.ID3Frame] { tag.frames.filter { $0.id == id } }

        // Changed fields were replaced, not duplicated.
        #expect(frames("TIT2").count == 1)
        #expect(utf16Text(frames("TIT2")[0].payload) == "New Title")

        // Untouched fields and frames the app doesn't manage are still there, unmodified.
        #expect(frames("TPE1").map(\.raw) == [fixture.frames["artist"]!])
        #expect(frames("USLT").map(\.raw) == [fixture.frames["lyrics"]!])
        #expect(frames("POPM").map(\.raw) == [fixture.frames["rating"]!])
        #expect(frames("TXXX").map(\.raw) == [fixture.frames["replaygain"]!])
        if version == 3 { #expect(frames("TDAT").map(\.raw) == [fixture.frames["date"]!]) }

        // Only the user's comment was replaced; iTunes' Sound Check frame survived.
        let comments = frames("COMM")
        #expect(comments.count == 2)
        #expect(comments.contains { $0.raw == fixture.frames["soundcheck"]! })
        #expect(!comments.contains { $0.raw == fixture.frames["comment"]! })
        let newComment = try #require(comments.first { $0.raw != fixture.frames["soundcheck"]! })
        #expect(String(data: newComment.payload.dropFirst(10), encoding: .utf16LittleEndian) == "new comment")

        // The year is stored in the frame this tag version uses.
        #expect(frames(version == 4 ? "TDRC" : "TYER").count == 1)
        #expect(frames(version == 4 ? "TYER" : "TDRC").isEmpty)
        #expect(utf16Text(frames(version == 4 ? "TDRC" : "TYER")[0].payload) == "2005")

        // The front cover was replaced; the back cover stayed.
        let pictures = frames("APIC")
        #expect(pictures.count == 2)
        #expect(pictures.contains { $0.raw == fixture.frames["back"]! })
        #expect(!pictures.contains { $0.raw == fixture.frames["front"]! })
    }

    @Test func clearingAFieldRemovesOnlyThatFrame() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeMP3(version: 3, in: directory)

        let original = makeSong(at: fixture.url)
        var withComment = original
        withComment.comment = "old comment"
        var cleared = withComment
        cleared.comment = nil
        cleared.artworkData = nil
        withComment.artworkData = pngA

        try await SongMetadataWriter.write(cleared, replacing: withComment, to: fixture.url)

        let tag = try readTag(fixture.url)
        let comments = tag.frames.filter { $0.id == "COMM" }
        #expect(comments.map(\.raw) == [fixture.frames["soundcheck"]!])
        #expect(tag.frames.filter { $0.id == "APIC" }.map(\.raw) == [fixture.frames["back"]!])
        #expect(tag.frames.contains { $0.id == "USLT" })
    }

    @Test func savingWithoutChangesLeavesTheFileAlone() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeMP3(version: 3, in: directory)
        let before = try Data(contentsOf: fixture.url)

        let song = makeSong(at: fixture.url)
        try await SongMetadataWriter.write(song, replacing: song, to: fixture.url)

        #expect(try Data(contentsOf: fixture.url) == before)
    }

    @Test func fieldsTheAppFailedToReadAreNotOverwrittenWithPlaceholders() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeMP3(version: 3, in: directory)

        // The app showed "Unknown Artist" (e.g. it couldn't read the tag); the user only retitled it.
        let original = makeSong(at: fixture.url, artist: "Unknown Artist", album: "Unknown Album")
        var edited = original
        edited.title = "New Title"

        try await SongMetadataWriter.write(edited, replacing: original, to: fixture.url)

        let tag = try readTag(fixture.url)
        #expect(tag.frames.filter { $0.id == "TPE1" }.map(\.raw) == [fixture.frames["artist"]!])
    }

    @Test func fileWithoutATagGetsOneAndKeepsItsAudio() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = fakeAudio()
        let url = directory.appendingPathComponent("bare.mp3")
        try audio.write(to: url)

        let original = makeSong(at: url, title: "bare")
        var edited = original
        edited.title = "Titled"
        try await SongMetadataWriter.write(edited, replacing: original, to: url)

        let tag = try readTag(url)
        #expect(tag.majorVersion == 3)
        #expect(tag.frames.map(\.id) == ["TIT2"])
        #expect(try Data(contentsOf: url).suffix(audio.count) == audio)
    }

    @Test func footerAndExtendedHeaderAreAccountedFor() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // v2.4 with a footer: the audio starts after it.
        let withFooter = try makeMP3(version: 4, flags: 0x10, footer: true, in: directory)
        let original = makeSong(at: withFooter.url)
        var edited = original
        edited.title = "Footer Test"
        try await SongMetadataWriter.write(edited, replacing: original, to: withFooter.url)
        #expect(try Data(contentsOf: withFooter.url).suffix(withFooter.audio.count) == withFooter.audio)
        #expect(try readTag(withFooter.url).frames.contains { $0.id == "USLT" })

        // v2.3 with an extended header (size excludes itself): frames start after it.
        let extended = Data(be32(6)) + Data(count: 6)
        let withExtended = try makeMP3(version: 3, flags: 0x40, extendedHeader: extended, in: try makeTempDirectory())
        defer { try? FileManager.default.removeItem(at: withExtended.url.deletingLastPathComponent()) }
        let original2 = makeSong(at: withExtended.url)
        var edited2 = original2
        edited2.title = "Extended Test"
        try await SongMetadataWriter.write(edited2, replacing: original2, to: withExtended.url)
        let tag = try readTag(withExtended.url)
        #expect(tag.frames.contains { $0.id == "USLT" })
        #expect(try Data(contentsOf: withExtended.url).suffix(withExtended.audio.count) == withExtended.audio)
    }

    @Test func tagsThatCannotBeRewrittenSafelyAreRefusedAndLeftAlone() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // ID3v2.2 (3-character frame IDs) and unsynchronised tags.
        var v22 = Data([0x49, 0x44, 0x33, 2, 0, 0]) + syncsafe(20) + Data(count: 20)
        v22.append(fakeAudio(100))
        var unsync = Data([0x49, 0x44, 0x33, 3, 0, 0x80]) + syncsafe(20) + Data(count: 20)
        unsync.append(fakeAudio(100))

        for (name, bytes) in [("v22.mp3", v22), ("unsync.mp3", unsync)] {
            let url = directory.appendingPathComponent(name)
            try bytes.write(to: url)
            let original = makeSong(at: url)
            var edited = original
            edited.title = "Changed"
            await #expect(throws: SongMetadataWriteError.self) {
                try await SongMetadataWriter.write(edited, replacing: original, to: url)
            }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func aTagThatDoesNotParseIsRefusedNotTruncated() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A frame whose declared size runs past the end of the tag.
        var body = Data("TIT2".utf8) + be32(5_000) + Data([0, 0]) + Data("short".utf8)
        body.append(Data(count: 10))
        var bytes = Data([0x49, 0x44, 0x33, 3, 0, 0]) + syncsafe(body.count) + body
        bytes.append(fakeAudio(100))
        let url = directory.appendingPathComponent("broken.mp3")
        try bytes.write(to: url)

        let original = makeSong(at: url)
        var edited = original
        edited.title = "Changed"
        await #expect(throws: SongMetadataWriteError.self) {
            try await SongMetadataWriter.write(edited, replacing: original, to: url)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }
}

// MARK: - FLAC

@MainActor
struct FLACWriterTests {

    private func block(_ type: UInt8, _ payload: Data, last: Bool = false) -> Data {
        Data([type | (last ? 0x80 : 0), UInt8((payload.count >> 16) & 0xFF), UInt8((payload.count >> 8) & 0xFF), UInt8(payload.count & 0xFF)]) + payload
    }

    private func vorbis(vendor: String, _ comments: [String]) -> Data {
        var data = le32(vendor.utf8.count) + Data(vendor.utf8) + le32(comments.count)
        for comment in comments { data.append(le32(comment.utf8.count)); data.append(Data(comment.utf8)) }
        return data
    }

    private func picture(type: Int, image: Data) -> Data {
        let mime = Data("image/png".utf8)
        return be32(type) + be32(mime.count) + mime + be32(0) + be32(1) + be32(1) + be32(0) + be32(0) + be32(image.count) + image
    }

    private func parse(_ data: Data) -> (blocks: [(type: UInt8, last: Bool, payload: Data)], audio: Data) {
        var blocks: [(type: UInt8, last: Bool, payload: Data)] = []
        var offset = 4
        var last = false
        while !last {
            let header = data[offset]
            last = header & 0x80 != 0
            let length = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            blocks.append((header & 0x7F, last, data.subdata(in: offset + 4..<offset + 4 + length)))
            offset += 4 + length
        }
        return (blocks, data.subdata(in: offset..<data.count))
    }

    private func makeFLAC(in directory: URL) throws -> (url: URL, audio: Data) {
        let audio = fakeAudio()
        var file = Data("fLaC".utf8)
        file.append(block(0, Data(count: 34)))
        file.append(block(4, vorbis(vendor: "reference libFLAC", [
            "TITLE=Old Title", "ARTIST=Real Artist", "artist=Second Artist", "ALBUM=Real Album",
            "LYRICS=la la la", "REPLAYGAIN_TRACK_GAIN=-6.5 dB", "MUSICBRAINZ_TRACKID=abc"
        ])))
        file.append(block(6, picture(type: 3, image: pngA)))
        file.append(block(6, picture(type: 4, image: pngB)))
        file.append(block(1, Data(count: 64), last: true))
        file.append(audio)
        let url = directory.appendingPathComponent("song.flac")
        try file.write(to: url)
        return (url, audio)
    }

    @Test func editingKeepsOtherCommentsPicturesAndTheVendor() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeFLAC(in: directory)

        // The app couldn't read FLAC tags, so everything but the title shows placeholders.
        let original = makeSong(at: fixture.url, artist: "Unknown Artist", album: "Unknown Album")
        var edited = original
        edited.title = "New Title"
        edited.composer = "New Composer"
        edited.artworkData = pngA   // different from the file's front cover bytes? same bytes: still "changed" from nil
        try await SongMetadataWriter.write(edited, replacing: original, to: fixture.url)

        let result = parse(try Data(contentsOf: fixture.url))
        #expect(result.audio == fixture.audio)
        #expect(result.blocks.first?.type == 0)                       // STREAMINFO still first
        #expect(result.blocks.filter(\.last).count == 1)              // exactly one "last block" flag...
        #expect(result.blocks.last?.last == true)                     // ...on the final block

        let commentBlocks = result.blocks.filter { $0.type == 4 }
        #expect(commentBlocks.count == 1)
        let parsed = try SongMetadataWriter.parseVorbisComment(commentBlocks[0].payload)
        #expect(parsed.vendor == "reference libFLAC")
        #expect(parsed.comments.filter { $0.hasPrefix("TITLE=") } == ["TITLE=New Title"])
        #expect(parsed.comments.contains("COMPOSER=New Composer"))
        // Not edited, so untouched: both artists, the album, and everything the app doesn't manage.
        #expect(parsed.comments.contains("ARTIST=Real Artist"))
        #expect(parsed.comments.contains("artist=Second Artist"))
        #expect(parsed.comments.contains("ALBUM=Real Album"))
        #expect(parsed.comments.contains("LYRICS=la la la"))
        #expect(parsed.comments.contains("REPLAYGAIN_TRACK_GAIN=-6.5 dB"))
        #expect(parsed.comments.contains("MUSICBRAINZ_TRACKID=abc"))

        // Front cover replaced, back cover kept.
        let pictureTypes = result.blocks.filter { $0.type == 6 }.map { Int(le32Free($0.payload)) }
        #expect(pictureTypes.sorted() == [3, 4])
        #expect(result.blocks.contains { $0.type == 1 })              // padding block survived
    }

    // The first four bytes of a PICTURE block are its big-endian picture type.
    private func le32Free(_ payload: Data) -> UInt32 {
        (UInt32(payload[0]) << 24) | (UInt32(payload[1]) << 16) | (UInt32(payload[2]) << 8) | UInt32(payload[3])
    }

    @Test func changingAnEditedFieldReplacesEveryCaseVariantOfIt() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeFLAC(in: directory)

        let original = makeSong(at: fixture.url)
        var edited = original
        edited.artist = "Only Artist"
        try await SongMetadataWriter.write(edited, replacing: original, to: fixture.url)

        let result = parse(try Data(contentsOf: fixture.url))
        let parsed = try SongMetadataWriter.parseVorbisComment(result.blocks.first { $0.type == 4 }!.payload)
        #expect(parsed.comments.filter { $0.uppercased().hasPrefix("ARTIST=") } == ["ARTIST=Only Artist"])
        #expect(parsed.comments.contains("TITLE=Old Title"))
    }

    @Test func notAFLACFileIsRefused() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fake.flac")
        try Data("not flac".utf8).write(to: url)
        let original = makeSong(at: url)
        var edited = original
        edited.title = "x"
        await #expect(throws: SongMetadataWriteError.self) {
            try await SongMetadataWriter.write(edited, replacing: original, to: url)
        }
    }
}

// MARK: - WAV

@MainActor
struct WAVWriterTests {

    private func chunk(_ id: String, _ payload: Data) -> Data {
        var data = Data(id.utf8) + le32(payload.count) + payload
        if payload.count % 2 != 0 { data.append(0) }
        return data
    }

    private func infoEntry(_ id: String, _ text: String) -> Data {
        chunk(id, Data(text.utf8) + Data([0]))
    }

    private func chunks(of data: Data) -> [(id: String, payload: Data)] {
        var result: [(id: String, payload: Data)] = []
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data.subdata(in: offset..<offset + 4), as: UTF8.self)
            let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
            result.append((id, data.subdata(in: offset + 8..<offset + 8 + size)))
            offset += 8 + size + (size % 2)
        }
        return result
    }

    @Test func editingKeepsOtherInfoEntriesAndTheAudio() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fmt = chunk("fmt ", Data([1, 0, 1, 0, 0x44, 0xAC, 0, 0, 0x88, 0x58, 1, 0, 2, 0, 16, 0]))
        let audio = fakeAudio(1000)
        let info = Data("INFO".utf8) + infoEntry("INAM", "Old Title") + infoEntry("ISFT", "Lavf58") + infoEntry("ICOP", "(c) Someone")
        var body = Data("WAVE".utf8)
        body.append(fmt)
        body.append(chunk("LIST", info))
        body.append(chunk("data", audio))
        let file = Data("RIFF".utf8) + le32(body.count) + body
        let url = directory.appendingPathComponent("song.wav")
        try file.write(to: url)

        let original = makeSong(at: url)
        var edited = original
        edited.title = "New Title"
        edited.comment = "a comment"
        try await SongMetadataWriter.write(edited, replacing: original, to: url)

        let written = try Data(contentsOf: url)
        let size = Int(written[4]) | Int(written[5]) << 8 | Int(written[6]) << 16 | Int(written[7]) << 24
        #expect(size == written.count - 8)

        let top = chunks(of: written)
        #expect(top.first { $0.id == "data" }?.payload == audio)
        #expect(top.first { $0.id == "fmt " }?.payload.count == 16)

        let list = try #require(top.first { $0.id == "LIST" })
        #expect(list.payload.prefix(4) == Data("INFO".utf8))
        let text = String(decoding: list.payload, as: UTF8.self)
        #expect(text.contains("New Title"))
        #expect(!text.contains("Old Title"))
        #expect(text.contains("Lavf58"))
        #expect(text.contains("(c) Someone"))
        #expect(text.contains("a comment"))
    }
}

// MARK: - MPEG-4 (a real AAC file)

@MainActor
struct MPEG4WriterTests {

    // Encodes a second of audio to AAC in an .m4a container.
    private func makeM4A(in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            buffer.frameLength = 44100
            let samples = buffer.floatChannelData![0]
            for index in 0..<44100 { samples[index] = 0.1 * sinf(Float(index) / 20) }
            try file.write(from: buffer)
        } // the file is finalized when it goes out of scope
        return url
    }

    private func lyricsItem(_ text: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .iTunesMetadataLyrics
        item.value = text as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    private func titleItem(_ text: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .iTunesMetadataSongName
        item.value = text as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    private func composerItem(_ text: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .iTunesMetadataComposer
        item.value = text as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    // Re-muxes `source` with the given tags, as a stand-in for a file tagged by another program.
    private func tag(_ source: URL, with items: [AVMetadataItem], into destination: URL) async throws {
        let export = try #require(AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough))
        export.metadata = items
        try await export.export(to: destination, as: .m4a)
    }

    private func strings(in url: URL, for identifier: AVMetadataIdentifier) async throws -> [String] {
        let items = try await AVURLAsset(url: url).load(.metadata)
        var result: [String] = []
        for item in items where item.identifier == identifier {
            if let text = try await item.load(.stringValue) { result.append(text) }
        }
        return result
    }

    @Test func editingKeepsTagsTheAppDoesNotManage() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plain = try makeM4A(in: directory, name: "plain.m4a")
        let url = directory.appendingPathComponent("tagged.m4a")
        try await tag(plain, with: [titleItem("Old Title"), lyricsItem("la la la")], into: url)
        #expect(try await strings(in: url, for: .iTunesMetadataLyrics) == ["la la la"])

        var original = makeSong(at: url)
        original.title = "Old Title"
        var edited = original
        edited.title = "New Title"
        edited.composer = "New Composer"
        try await SongMetadataWriter.write(edited, replacing: original, to: url)

        #expect(try await strings(in: url, for: .iTunesMetadataSongName) == ["New Title"])
        #expect(try await strings(in: url, for: .iTunesMetadataComposer) == ["New Composer"])
        // The lyrics were not part of the edit and must still be there, exactly once.
        #expect(try await strings(in: url, for: .iTunesMetadataLyrics) == ["la la la"])

        // And the result is still a playable file of the same length.
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 1.0) < 0.1)
    }

    @Test func clearingAFieldRemovesItFromTheFile() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plain = try makeM4A(in: directory, name: "plain.m4a")
        let url = directory.appendingPathComponent("tagged.m4a")
        try await tag(plain, with: [titleItem("A Title"), composerItem("Someone"), lyricsItem("keep me")], into: url)
        #expect(try await strings(in: url, for: .iTunesMetadataComposer) == ["Someone"])

        var original = makeSong(at: url)
        original.title = "A Title"
        original.composer = "Someone"
        var edited = original
        edited.composer = nil
        try await SongMetadataWriter.write(edited, replacing: original, to: url)

        #expect(try await strings(in: url, for: .iTunesMetadataComposer).isEmpty)
        #expect(try await strings(in: url, for: .iTunesMetadataSongName) == ["A Title"])
        #expect(try await strings(in: url, for: .iTunesMetadataLyrics) == ["keep me"])
    }
}
