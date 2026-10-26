//
//  ClassicTunesTests.swift
//  ClassicTunesTests
//
//  Created by Smaran Vallabhaneni on 29/10/25,
//  but never actually even edited until 26/10/26.

import Testing
import Foundation
@testable import ClassicTunes

// MARK: - Helpers

// Builds a dummy song with "sensible" defaults so tests only specify what it wants.
private func makeSong(
    title: String = "Title",
    artist: String = "Artist",
    album: String = "Album",
    genre: String = "Rock",
    year: String? = nil,
    trackNumber: Int? = nil,
    discNumber: Int? = nil,
    composer: String? = nil,
    comment: String? = nil,
    albumArtist: String? = nil,
    grouping: String? = nil,
    bpm: Int? = nil,
    duration: TimeInterval? = nil,
    playCount: Int = 0
) -> Song {
    Song(
        url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mp3"),
        title: title, artist: artist, album: album, year: year, genre: genre,
        trackNumber: trackNumber, discNumber: discNumber, composer: composer,
        comment: comment, albumArtist: albumArtist, grouping: grouping,
        bpm: bpm, duration: duration, playCount: playCount
    )
}

private func rule(_ field: SmartRuleField, _ op: SmartRuleOperator, _ value: String, _ second: String = "") -> SmartRule {
    SmartRule(field: field, op: op, value: value, secondValue: second)
}

// MARK: - Smart rule field / operator metadata

@MainActor
struct SmartRuleMetadataTests {

    @Test func numericFieldsAreFlaggedNumeric() {
        let numeric: [SmartRuleField] = [.year, .playCount, .bpm, .trackNumber, .discNumber, .duration]
        for field in SmartRuleField.allCases {
            #expect(field.isNumeric == numeric.contains(field))
        }
    }

    @Test func fieldsOfferMatchingOperators() {
        #expect(SmartRuleField.artist.availableOperators == SmartRuleOperator.textOperators)
        #expect(SmartRuleField.year.availableOperators == SmartRuleOperator.numericOperators)
    }

    @Test func operatorListsCoverEveryOperatorExactlyOnce() {
        let combined = SmartRuleOperator.textOperators + SmartRuleOperator.numericOperators
        #expect(Set(combined) == Set(SmartRuleOperator.allCases))
        #expect(combined.count == SmartRuleOperator.allCases.count)
    }
}

// MARK: - SmartRule

@MainActor
struct SmartRuleTests {

    // MARK: Completeness

    @Test func emptyOrWhitespaceValueIsIncomplete() {
        #expect(!rule(.artist, .contains, "").isComplete)
        #expect(!rule(.artist, .contains, "   ").isComplete)
        #expect(rule(.artist, .contains, "Beatles").isComplete)
    }

    @Test func rangeRuleNeedsSecondValue() {
        #expect(!rule(.year, .inRange, "1990").isComplete)
        #expect(!rule(.year, .inRange, "1990", "  ").isComplete)
        #expect(rule(.year, .inRange, "1990", "1999").isComplete)
    }

    // MARK: Text operators

    @Test func containsIsCaseInsensitive() {
        let song = makeSong(artist: "The Beatles")
        #expect(rule(.artist, .contains, "beat").matches(song))
        #expect(!rule(.artist, .contains, "stones").matches(song))
    }

    @Test func doesNotContainIsInverseOfContains() {
        let song = makeSong(artist: "The Beatles")
        #expect(rule(.artist, .doesNotContain, "stones").matches(song))
        #expect(!rule(.artist, .doesNotContain, "BEATLES").matches(song))
    }

    @Test func isAndIsNotRequireWholeValue() {
        let song = makeSong(album: "Abbey Road")
        #expect(rule(.album, .is, "abbey road").matches(song))
        #expect(!rule(.album, .is, "Abbey").matches(song))
        #expect(rule(.album, .isNot, "Abbey").matches(song))
        #expect(!rule(.album, .isNot, "ABBEY ROAD").matches(song))
    }

    @Test func startsWithAndEndsWithAnchorToTheEdges() {
        let song = makeSong(title: "Come Together")
        #expect(rule(.title, .startsWith, "come").matches(song))
        #expect(!rule(.title, .startsWith, "together").matches(song))
        #expect(rule(.title, .endsWith, "TOGETHER").matches(song))
        #expect(!rule(.title, .endsWith, "come").matches(song))
    }

    @Test func valueIsTrimmedBeforeComparing() {
        #expect(rule(.genre, .is, "  rock  ").matches(makeSong(genre: "Rock")))
    }

    @Test func missingOptionalTextFieldsActLikeEmptyStrings() {
        let song = makeSong()
        #expect(!rule(.composer, .contains, "Bach").matches(song))
        #expect(rule(.composer, .doesNotContain, "Bach").matches(song))
        #expect(rule(.albumArtist, .isNot, "Someone").matches(song))
    }

    @Test func optionalTextFieldsAreReadFromTheRightProperty() {
        let song = makeSong(composer: "Bach", comment: "live", albumArtist: "Various", grouping: "Suite")
        #expect(rule(.composer, .is, "Bach").matches(song))
        #expect(rule(.comment, .is, "live").matches(song))
        #expect(rule(.albumArtist, .is, "Various").matches(song))
        #expect(rule(.grouping, .is, "Suite").matches(song))
    }

    @Test func numericOperatorOnTextFieldNeverMatches() {
        #expect(!rule(.artist, .equals, "Artist").matches(makeSong()))
    }

    // MARK: Numeric operators

    @Test func equalsAndNotEquals() {
        let song = makeSong(bpm: 120)
        #expect(rule(.bpm, .equals, "120").matches(song))
        #expect(!rule(.bpm, .equals, "121").matches(song))
        #expect(rule(.bpm, .notEquals, "121").matches(song))
        #expect(!rule(.bpm, .notEquals, "120").matches(song))
    }

    @Test func greaterAndLessThanAreStrict() {
        let song = makeSong(playCount: 10)
        #expect(rule(.playCount, .greaterThan, "9").matches(song))
        #expect(!rule(.playCount, .greaterThan, "10").matches(song))
        #expect(rule(.playCount, .lessThan, "11").matches(song))
        #expect(!rule(.playCount, .lessThan, "10").matches(song))
    }

    @Test func inRangeIsInclusiveAndAcceptsReversedBounds() {
        let song = makeSong(trackNumber: 5)
        #expect(rule(.trackNumber, .inRange, "1", "5").matches(song))
        #expect(rule(.trackNumber, .inRange, "5", "10").matches(song))
        #expect(rule(.trackNumber, .inRange, "10", "1").matches(song))
        #expect(!rule(.trackNumber, .inRange, "6", "10").matches(song))
    }

    @Test func inRangeWithUnparsableUpperBoundDoesNotMatch() {
        #expect(!rule(.trackNumber, .inRange, "1", "abc").matches(makeSong(trackNumber: 2)))
    }

    @Test func yearUsesTheFirstFourCharactersOfTheDate() {
        let song = makeSong(year: "1995-03-21")
        #expect(rule(.year, .equals, "1995").matches(song))
        #expect(rule(.year, .inRange, "1990", "1999").matches(song))
        #expect(rule(.year, .greaterThan, "1994").matches(song))
    }

    @Test func missingNumericAttributeOnlyMatchesNotEquals() {
        let song = makeSong()   // no bpm, year, track, disc, duration
        #expect(rule(.bpm, .notEquals, "100").matches(song))
        #expect(!rule(.bpm, .equals, "100").matches(song))
        #expect(!rule(.bpm, .greaterThan, "0").matches(song))
        #expect(!rule(.bpm, .lessThan, "1000").matches(song))
        #expect(!rule(.year, .equals, "2000").matches(song))
    }

    @Test func nonNumericValueNeverMatchesNumericRule() {
        #expect(!rule(.playCount, .equals, "lots").matches(makeSong(playCount: 3)))
        #expect(!rule(.playCount, .notEquals, "lots").matches(makeSong(playCount: 3)))
    }

    @Test func durationComparesInSeconds() {
        let song = makeSong(duration: 215.5)
        #expect(rule(.duration, .greaterThan, "200").matches(song))
        #expect(rule(.duration, .lessThan, "216").matches(song))
    }

    @Test func discNumberIsComparedNumerically() {
        #expect(rule(.discNumber, .equals, "2").matches(makeSong(discNumber: 2)))
    }

    // MARK: Codable

    @Test func ruleSurvivesCodableRoundTrip() throws {
        let original = rule(.year, .inRange, "1990", "1999")
        let decoded = try JSONDecoder().decode(SmartRule.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}

// MARK: - SmartPlaylistRules

@MainActor
struct SmartPlaylistRulesTests {

    private let library = [
        makeSong(title: "Alpha", artist: "Beatles", year: "1969", playCount: 5),
        makeSong(title: "Bravo", artist: "Beatles", year: "1965", playCount: 20),
        makeSong(title: "Charlie", artist: "Stones", year: "1971", playCount: 1),
        makeSong(title: "Delta", artist: "Queen", year: nil, playCount: 12)
    ]

    private func titles(_ songs: [Song]) -> [String] { songs.map(\.title) }

    @Test func matchAllRequiresEveryRule() {
        var definition = SmartPlaylistRules(rules: [
            rule(.artist, .is, "Beatles"),
            rule(.playCount, .greaterThan, "10")
        ])
        definition.matchAll = true
        #expect(titles(definition.songs(from: library)) == ["Bravo"])
    }

    @Test func matchAnyAcceptsASingleMatchingRule() {
        var definition = SmartPlaylistRules(rules: [
            rule(.artist, .is, "Stones"),
            rule(.artist, .is, "Queen")
        ])
        definition.matchAll = false
        #expect(titles(definition.songs(from: library)) == ["Charlie", "Delta"])
    }

    @Test func incompleteRulesAreIgnored() {
        let definition = SmartPlaylistRules(rules: [
            rule(.artist, .is, "Beatles"),
            rule(.title, .contains, "")     // incomplete, must not filter everything out
        ])
        #expect(titles(definition.songs(from: library)) == ["Alpha", "Bravo"])
    }

    @Test func noActiveRulesProducesAnEmptyPlaylist() {
        #expect(SmartPlaylistRules(rules: []).songs(from: library).isEmpty)
        #expect(SmartPlaylistRules(rules: [rule(.artist, .contains, "")]).songs(from: library).isEmpty)
    }

    @Test func defaultDefinitionStartsWithOneBlankRule() {
        let definition = SmartPlaylistRules()
        #expect(definition.rules.count == 1)
        #expect(definition.matchAll)
        #expect(!definition.limitEnabled)
        #expect(definition.songs(from: library).isEmpty)
    }

    @Test func duplicateSongsInLibraryAppearOnce() {
        let song = library[0]
        let definition = SmartPlaylistRules(rules: [rule(.title, .is, "Alpha")])
        #expect(definition.songs(from: [song, song, song]).count == 1)
    }

    @Test func limitIsIgnoredWhenDisabled() {
        var definition = SmartPlaylistRules(rules: [rule(.title, .contains, "a")])
        definition.limitEnabled = false
        definition.limit = 1
        #expect(definition.songs(from: library).count == 4)
    }

    @Test func mostPlayedKeepsHighestPlayCountsFirst() {
        var definition = SmartPlaylistRules(rules: [rule(.title, .contains, "a")])
        definition.limitEnabled = true
        definition.limit = 2
        definition.selection = .mostPlayed
        #expect(titles(definition.songs(from: library)) == ["Bravo", "Delta"])
    }

    @Test func leastPlayedKeepsLowestPlayCountsFirst() {
        var definition = SmartPlaylistRules(rules: [rule(.title, .contains, "a")])
        definition.limitEnabled = true
        definition.limit = 2
        definition.selection = .leastPlayed
        #expect(titles(definition.songs(from: library)) == ["Charlie", "Alpha"])
    }

    @Test func alphabeticalSelectionsSortByTheirField() {
        var definition = SmartPlaylistRules(rules: [rule(.title, .contains, "a")])
        definition.limitEnabled = true
        definition.limit = 10

        definition.selection = .title
        #expect(titles(definition.songs(from: library)) == ["Alpha", "Bravo", "Charlie", "Delta"])

        definition.selection = .artist
        #expect(definition.songs(from: library).map(\.artist) == ["Beatles", "Beatles", "Queen", "Stones"])
    }

    @Test func yearSelectionsPutSongsWithoutAYearLast() {
        var definition = SmartPlaylistRules(rules: [rule(.title, .contains, "a")])
        definition.limitEnabled = true
        definition.limit = 10

        definition.selection = .newestYear
        #expect(titles(definition.songs(from: library)) == ["Charlie", "Alpha", "Bravo", "Delta"])

        definition.selection = .oldestYear
        #expect(titles(definition.songs(from: library)) == ["Bravo", "Alpha", "Charlie", "Delta"])
    }

    @Test func randomSelectionRespectsLimitAndSourceSongs() {
        var definition = SmartPlaylistRules(rules: [rule(.title, .contains, "a")])
        definition.limitEnabled = true
        definition.limit = 3
        definition.selection = .random
        let result = definition.songs(from: library)
        #expect(result.count == 3)
        #expect(Set(result.map(\.id)).isSubset(of: Set(library.map(\.id))))
    }

    @Test func zeroOrNegativeLimitYieldsNoSongs() {
        var definition = SmartPlaylistRules(rules: [rule(.title, .contains, "a")])
        definition.limitEnabled = true
        definition.limit = 0
        #expect(definition.songs(from: library).isEmpty)
        definition.limit = -5
        #expect(definition.songs(from: library).isEmpty)
    }

    @Test func limitLargerThanResultsReturnsEverything() {
        var definition = SmartPlaylistRules(rules: [rule(.title, .contains, "a")])
        definition.limitEnabled = true
        definition.limit = 100
        #expect(definition.songs(from: library).count == 4)
    }

    @Test func definitionSurvivesCodableRoundTrip() throws {
        var original = SmartPlaylistRules(rules: [rule(.year, .inRange, "1960", "1970")])
        original.matchAll = false
        original.limitEnabled = true
        original.limit = 7
        original.selection = .oldestYear
        let decoded = try JSONDecoder().decode(SmartPlaylistRules.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}

// MARK: - Playlist

@MainActor
struct PlaylistTests {

    @Test func regularPlaylistIsNotSmart() {
        #expect(!Playlist(name: "Mix", songs: []).isSmart)
    }

    @Test func smartPlaylistIsSmart() {
        #expect(Playlist(name: "Smart", songs: [], smartRules: SmartPlaylistRules()).isSmart)
    }

    @Test func resolvingRegularPlaylistReturnsItUnchanged() {
        let song = makeSong(title: "Kept")
        let playlist = Playlist(name: "Mix", songs: [song])
        let resolved = playlist.resolved(against: [makeSong(title: "Other")])
        #expect(resolved.id == playlist.id)
        #expect(resolved.songs.map(\.id) == [song.id])
    }

    @Test func resolvingSmartPlaylistFillsSongsFromLibrary() {
        let match = makeSong(artist: "Queen")
        let miss = makeSong(artist: "Abba")
        let smart = Playlist(
            name: "Queen",
            songs: [],
            smartRules: SmartPlaylistRules(rules: [rule(.artist, .is, "Queen")])
        )
        let resolved = smart.resolved(against: [match, miss])
        #expect(resolved.id == smart.id)
        #expect(resolved.songs.map(\.id) == [match.id])
    }

    @Test func userPlaylistDisplayNameIsItsName() {
        #expect(Playlist(name: "Road Trip", songs: []).displayName == "Road Trip")
    }

    @Test func systemPlaylistWithUnknownNameKeepsItsName() {
        #expect(Playlist(name: "Library", songs: [], isSystem: true).displayName == "Library")
    }

    @Test func nonSystemPlaylistIgnoresSystemNameLocalization() {
        #expect(Playlist(name: "Recently Played", songs: []).displayName == "Recently Played")
    }

    @Test func playlistSurvivesCodableRoundTrip() throws {
        let song = makeSong(title: "Song", year: "2001")
        let original = Playlist(
            name: "Smart",
            songs: [song],
            smartRules: SmartPlaylistRules(rules: [rule(.title, .contains, "Song")])
        )
        let decoded = try JSONDecoder().decode(Playlist.self, from: JSONEncoder().encode(original))
        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.songs == original.songs)
        #expect(decoded.smartRules == original.smartRules)
        #expect(decoded.isSystem == original.isSystem)
    }
}

// MARK: - Song

@MainActor
struct SongTests {

    @Test func initializerDefaults() {
        let song = Song(url: URL(fileURLWithPath: "/tmp/a.mp3"), title: "T", artist: "A", album: "B", genre: "G")
        #expect(song.playCount == 0)
        #expect(!song.compilation)
        #expect(song.year == nil)
        #expect(song.artworkData == nil)
        #expect(song.artworkImage == nil)
    }

    @Test func songsWithDistinctIDsAreNotEqual() {
        let url = URL(fileURLWithPath: "/tmp/a.mp3")
        let a = Song(url: url, title: "T", artist: "A", album: "B", genre: "G")
        let b = Song(url: url, title: "T", artist: "A", album: "B", genre: "G")
        #expect(a != b)
    }

    @Test func songSurvivesCodableRoundTrip() throws {
        let original = makeSong(
            title: "Round Trip", year: "1999", trackNumber: 3, discNumber: 1,
            composer: "C", comment: "note", albumArtist: "AA", grouping: "G",
            bpm: 128, duration: 241.5, playCount: 9
        )
        let decoded = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}

// MARK: - normalizedSortKey

@MainActor
struct NormalizedSortKeyTests {

    @Test(arguments: [
        ("The Beatles", "Beatles"),
        ("the beatles", "beatles"),
        ("A Tribe Called Quest", "Tribe Called Quest"),
        ("An Horse with No Name", "Horse with No Name"),
        ("Queen", "Queen"),
        ("Another Brick", "Another Brick"),   // "An" must only match as a whole word
        ("Theory of a Deadman", "Theory of a Deadman"),
        ("  The Who  ", "Who"),
        ("...The Who", "Who"),
        ("\"Heroes\"", "Heroes\""),
        ("The", "The"),
        ("", ""),
        ("!!!", "!!!")
    ])
    func stripsLeadingArticlesAndSymbols(input: String, expected: String) {
        #expect(normalizedSortKey(input) == expected)
    }
}

// MARK: - Play history & analytics
//
// These helpers read and write `UserDefaults.standard`, so the suite is serialized and each test
// restores the keys it touches.

@MainActor
@Suite(.serialized)
struct PlayHistoryTests {

    private let touchedKeys = [playCountKey, playHistoryKey, lastPlayedKey]

    // Runs `body` and then puts the real defaults back exactly as they were.
    private func withPreservedDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = touchedKeys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(touchedKeys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        body()
    }

    @Test func playCountStartsAtZeroAndIncrements() {
        withPreservedDefaults {
            let song = makeSong()
            #expect(getPlayCount(for: song) == 0)
            incrementPlayCount(for: song)
            incrementPlayCount(for: song)
            #expect(getPlayCount(for: song) == 2)
        }
    }

    @Test func playCountsAreTrackedPerSong() {
        withPreservedDefaults {
            let a = makeSong(), b = makeSong()
            incrementPlayCount(for: a)
            #expect(getPlayCount(for: a) == 1)
            #expect(getPlayCount(for: b) == 0)
        }
    }

    @Test func historyListsMostRecentPlayFirst() {
        withPreservedDefaults {
            let a = makeSong(), b = makeSong()
            incrementPlayCount(for: a)
            incrementPlayCount(for: b)
            #expect(Array(getPlayHistory().prefix(2)) == [b.id.uuidString, a.id.uuidString])
        }
    }

    @Test func historyIsCappedAtOneThousandEntries() {
        withPreservedDefaults {
            UserDefaults.standard.set(Array(repeating: "old", count: 1000), forKey: playHistoryKey)
            let song = makeSong()
            incrementPlayCount(for: song)
            let history = getPlayHistory()
            #expect(history.count == 1000)
            #expect(history.first == song.id.uuidString)
        }
    }

    @Test func lastPlayedRoundTripsAndDefaultsToNil() {
        withPreservedDefaults {
            let song = makeSong()
            #expect(getLastPlayed(for: song) == nil)
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            recordLastPlayed(for: song, date: date)
            #expect(getLastPlayed(for: song) == date)
        }
    }

    @Test func recentlyPlayedPlaylistIsDeduplicatedAndOrdered() {
        withPreservedDefaults {
            let a = makeSong(), b = makeSong(), c = makeSong()
            incrementPlayCount(for: a)
            incrementPlayCount(for: b)
            incrementPlayCount(for: a)   // `a` is now the most recent, `b` second
            let playlist = generateRecentlyPlayedPlaylist(from: [a, b, c])
            #expect(playlist.isSystem)
            #expect(playlist.name == "Recently Played")
            #expect(playlist.songs.map(\.id) == [a.id, b.id])
        }
    }

    @Test func recentlyPlayedPlaylistRespectsMaxCount() {
        withPreservedDefaults {
            let songs = (0..<5).map { _ in makeSong() }
            songs.forEach { incrementPlayCount(for: $0) }
            let playlist = generateRecentlyPlayedPlaylist(from: songs, maxCount: 3)
            #expect(playlist.songs.count == 3)
            #expect(playlist.songs.map(\.id) == [songs[4].id, songs[3].id, songs[2].id])
        }
    }

    @Test func topPlayedSortsByCountThenTitle() {
        withPreservedDefaults {
            let low = makeSong(title: "Low")
            let tieB = makeSong(title: "B Tie")
            let tieA = makeSong(title: "A Tie")
            let top = makeSong(title: "Top")
            incrementPlayCount(for: top)
            incrementPlayCount(for: top)
            incrementPlayCount(for: top)
            incrementPlayCount(for: tieA)
            incrementPlayCount(for: tieA)
            incrementPlayCount(for: tieB)
            incrementPlayCount(for: tieB)
            incrementPlayCount(for: low)

            let playlist = generateTopPlayedPlaylist(from: [low, tieB, tieA, top])
            #expect(playlist.isSystem)
            #expect(playlist.name == "Top 25 Most Played")
            #expect(playlist.songs.map(\.title) == ["Top", "A Tie", "B Tie", "Low"])
        }
    }

    @Test func topPlayedPlaylistRespectsMaxCount() {
        withPreservedDefaults {
            let songs = (0..<5).map { makeSong(title: "Song \($0)") }
            let playlist = generateTopPlayedPlaylist(from: songs, maxCount: 2)
            #expect(playlist.songs.count == 2)
        }
    }
}
