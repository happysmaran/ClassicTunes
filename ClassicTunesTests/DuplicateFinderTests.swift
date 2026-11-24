import Foundation
import Testing
@testable import ClassicTunes

struct DuplicateFinderTests {
    private func song(_ title: String = "Song", artist: String = "Artist", album: String = "Album", year: String? = "2009",
                      track: Int? = 1, duration: TimeInterval? = 200, file: String = UUID().uuidString) -> Song {
        Song(url: URL(fileURLWithPath: "/tmp/\(file).mp3"), title: title, artist: artist, album: album, year: year,
             genre: "Rock", trackNumber: track, duration: duration)
    }

    @Test func groupsCopiesWithinTheDurationTolerance() {
        let groups = DuplicateFinder.groups(in: [song(duration: 200), song(duration: 201.9), song(duration: 205)])
        #expect(groups.count == 1)
        #expect(groups[0].count == 2)
    }

    @Test func ignoresCaseAccentsAndPunctuation() {
        let groups = DuplicateFinder.groups(in: [song("Café del Mar!"), song("cafe del mar")])
        #expect(groups.count == 1)
    }

    @Test func differentYearsAreNotDuplicates() {
        #expect(DuplicateFinder.groups(in: [song(year: "1987"), song(year: "2009")]).isEmpty)
    }

    @Test func aYearOnOnlyOneSideIsNotAMatch() {
        #expect(DuplicateFinder.groups(in: [song(year: nil), song(year: "2009")]).isEmpty)
        #expect(DuplicateFinder.groups(in: [song(year: nil), song(year: nil)]).count == 1)
    }

    @Test func fullDatesCompareByYear() {
        #expect(DuplicateFinder.groups(in: [song(year: "2009-09-09"), song(year: "2009")]).count == 1)
    }

    @Test func differentTrackNumbersAreNotDuplicates() {
        #expect(DuplicateFinder.groups(in: [song(track: 1), song(track: 2)]).isEmpty)
        #expect(DuplicateFinder.groups(in: [song(track: nil), song(track: 2)]).count == 1)
    }

    @Test func differentAlbumsOrMissingDurationsAreSkipped() {
        #expect(DuplicateFinder.groups(in: [song(album: "A"), song(album: "B")]).isEmpty)
        #expect(DuplicateFinder.groups(in: [song(duration: nil), song(duration: nil)]).isEmpty)
    }
}
