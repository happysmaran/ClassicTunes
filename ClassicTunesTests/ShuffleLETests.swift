import Testing
import Foundation
@testable import ClassicTunes

// There is no 3rd/4th generation Shuffle to test against, so these pin the layout to the
// structure documented for the format: if offsets or sizes drift, a device would reject the file.
struct ShuffleLETests {
    private func sample() -> iTunesSD_LEDatabase {
        var database = iTunesSD_LEDatabase()
        for (path, type) in [("/iPod_Control/Music/F00/AAAA.mp3", UInt32(1)), ("/iPod_Control/Music/F01/BBBB.m4a", 2)] {
            var track = iTunesSD_LETrack()
            track.filePath = path
            track.type = type
            database.append(track)
        }
        return database
    }

    @Test func headerAndTablesAreLocatedByOffset() throws {
        let data = sample().serialise()
        #expect(data.prefix(4) == Data("bdhs".utf8))
        #expect(data.readLE(UInt32.self, at: 8) == 64)
        #expect(data.readLE(UInt32.self, at: 12) == 2)
        let tracksOffset = Int(try #require(data.readLE(UInt32.self, at: 36)))
        let playlistsOffset = Int(try #require(data.readLE(UInt32.self, at: 40)))
        #expect(tracksOffset == 64)
        #expect(data[tracksOffset..<tracksOffset + 4] == Data("hths".utf8))
        #expect(data[playlistsOffset..<playlistsOffset + 4] == Data("hphs".utf8))
        // Two 372-byte records sit between the track table's 28 header bytes and the playlists.
        #expect(playlistsOffset == 64 + 20 + 2 * 4 + 2 * 372)
        #expect(data.count > playlistsOffset)
    }

    @Test func roundTripKeepsTracksAndMasterPlaylist() throws {
        let original = sample()
        let parsed = try iTunesSD_LEDatabase.parse(from: original.serialise())
        #expect(parsed.tracks.map(\.filePath) == original.tracks.map(\.filePath))
        #expect(parsed.tracks.map(\.type) == [1, 2])
        #expect(parsed.playlists.count == 1)
        #expect(parsed.playlists[0].type == iTunesSD_LEPlaylist.masterType)
        #expect(parsed.playlists[0].trackIndexes == [0, 1])
    }

    @Test func removingATrackShiftsPlaylistIndexes() throws {
        var database = try iTunesSD_LEDatabase.parse(from: sample().serialise())
        database.removeTrack(path: "/iPod_Control/Music/F00/AAAA.mp3")
        let reparsed = try iTunesSD_LEDatabase.parse(from: database.serialise())
        #expect(reparsed.tracks.map(\.filePath) == ["/iPod_Control/Music/F01/BBBB.m4a"])
        #expect(reparsed.playlists[0].trackIndexes == [0])
    }

    @Test func unknownBytesSurviveARewrite() throws {
        var data = sample().serialise()
        let firstRecord = 64 + 20 + 2 * 4
        data[firstRecord + 340] = 0xAB   // inside the undocumented tail of the track record
        let rewritten = try iTunesSD_LEDatabase.parse(from: data).serialise()
        #expect(rewritten[firstRecord + 340] == 0xAB)
    }

    @Test func groupingFieldsRoundTrip() throws {
        var database = iTunesSD_LEDatabase()
        var track = iTunesSD_LETrack()
        track.filePath = "/iPod_Control/Music/F00/AAAA.mp3"
        track.albumID = 7
        track.artistID = 3
        track.trackNumber = 5
        track.discNumber = 2
        database.append(track)
        let parsed = try iTunesSD_LEDatabase.parse(from: database.serialise()).tracks[0]
        #expect(parsed.albumID == 7)
        #expect(parsed.artistID == 3)
        #expect(parsed.trackNumber == 5)
        #expect(parsed.discNumber == 2)
        #expect(parsed.pregap == 0x200)
    }

    @Test func detectsTheFormatFromTheFileTag() {
        #expect(iTunesSD_LEDatabase.looksLikeLE(sample().serialise()))
        #expect(!iTunesSD_LEDatabase.looksLikeLE(iTunesSD_BEDatabase().serialise()))
    }
}
