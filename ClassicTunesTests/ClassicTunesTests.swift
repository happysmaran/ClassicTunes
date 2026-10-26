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

    @Test func songsWithDifferentFilesAreNotEqual() {
        let a = Song(url: URL(fileURLWithPath: "/tmp/a.mp3"), title: "T", artist: "A", album: "B", genre: "G")
        let b = Song(url: URL(fileURLWithPath: "/tmp/b.mp3"), title: "T", artist: "A", album: "B", genre: "G")
        #expect(a != b)
        #expect(a.id != b.id)
    }

    @Test func idIsStableForTheSameFile() {
        let url = URL(fileURLWithPath: "/tmp/music/a.mp3")
        let first = Song(url: url, title: "T", artist: "A", album: "B", genre: "G")
        let second = Song(url: url, title: "Other title", artist: "A", album: "B", genre: "G")
        #expect(first.id == second.id)
        #expect(first.id == Song.stableID(for: URL(fileURLWithPath: "/tmp/music/../music/a.mp3")))
    }

    @Test func explicitIDIsRespected() {
        let id = UUID()
        let song = Song(id: id, url: URL(fileURLWithPath: "/tmp/a.mp3"), title: "T", artist: "A", album: "B", genre: "G")
        #expect(song.id == id)
        #expect(song.withStableID().id == Song.stableID(for: song.url))
    }

    @Test func artworkIsStoredOutsideTheSong() throws {
        let png = Self.tinyPNG
        var song = makeSong()
        song.artworkData = png
        #expect(song.artworkKey != nil)
        #expect(song.artworkData == png)
        #expect(song.artworkImage != nil)

        // The saved form carries only the key, never the image bytes.
        let encoded = try JSONEncoder().encode(song)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("artworkKey"))
        #expect(!json.contains("\"artworkData\""))
        #expect(encoded.count < png.count + 1500)

        song.artworkData = nil
        #expect(song.artworkKey == nil)
    }

    @Test func sameArtworkOnDifferentSongsSharesOneKey() {
        var a = makeSong(), b = makeSong()
        a.artworkData = Self.tinyPNG
        b.artworkData = Self.tinyPNG
        #expect(a.artworkKey == b.artworkKey)
    }

    @Test func decodesSongsSavedByOlderVersions() throws {
        // Written before `compilation`, `playCount`, `artworkKey` and `dateAdded` existed, with the
        // artwork embedded in the song as base64.
        let png = Self.tinyPNG
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","url":"file:///tmp/old.mp3","title":"Old","artist":"A",
         "album":"B","genre":"G","artworkData":"\(png.base64EncodedString())"}
        """
        let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        #expect(song.title == "Old")
        #expect(!song.compilation)
        #expect(song.playCount == 0)
        #expect(song.artworkKey != nil)
        #expect(song.artworkData == png)
    }

    // A 1x1 PNG.
    static let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

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

// MARK: - Play counts

@MainActor
@Suite(.serialized)
struct BulkPlayCountTests {

    @Test func allPlayCountsMatchPerSongCounts() {
        let defaults = UserDefaults.standard
        let keys = [playCountKey, playHistoryKey, lastPlayedKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }

        let a = makeSong(), b = makeSong()
        incrementPlayCount(for: a)
        incrementPlayCount(for: a)
        incrementPlayCount(for: b)

        let counts = getAllPlayCounts()
        #expect(counts[a.id] == 2)
        #expect(counts[b.id] == 1)
        #expect(counts[a.id] == getPlayCount(for: a))
        // Playing a song also records when it was played.
        #expect(getLastPlayed(for: a) != nil)
    }

    @Test func countsSurviveARescanBecauseIDsAreStable() {
        let defaults = UserDefaults.standard
        let keys = [playCountKey, playHistoryKey, lastPlayedKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }

        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mp3")
        incrementPlayCount(for: Song(url: url, title: "T", artist: "A", album: "B", genre: "G"))
        // A later scan builds a brand-new Song value for the same file.
        let rescanned = Song(url: url, title: "T", artist: "A", album: "B", genre: "G")
        #expect(getPlayCount(for: rescanned) == 1)
    }
}

// MARK: - Playlist persistence

@MainActor
struct PlaylistStoreTests {

    private func makeStore() throws -> (store: PlaylistStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (PlaylistStore(directory: directory), directory)
    }

    @Test func savedPlaylistsLoadBack() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let song = makeSong(title: "Kept")
        let playlist = Playlist(name: "Mix", songs: [song])
        store.save([playlist])

        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == playlist.id)
        #expect(loaded[0].songs.map(\.title) == ["Kept"])
    }

    @Test func songsSavedWithRandomIDsAreRelinkedByPath() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mp3")
        let legacy = Song(id: UUID(), url: url, title: "Legacy", artist: "A", album: "B", genre: "G")
        store.save([Playlist(name: "Old", songs: [legacy])])

        let loaded = store.load()
        #expect(loaded[0].songs[0].id == Song.stableID(for: url))
    }

    @Test func unreadableFileIsSetAsideNotOverwritten() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("userPlaylists.v1.json")
        try Data("{ not json".utf8).write(to: file)

        #expect(store.load().isEmpty)

        // The broken file was moved aside rather than left to be replaced by the next save.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.contains { $0.hasPrefix("userPlaylists.v1.unreadable-") })
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func backupIsUsedWhenTheMainFileIsUnreadable() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlist = Playlist(name: "Precious", songs: [makeSong()])
        store.save([playlist])
        store.save([playlist])   // The second save leaves the first version as the backup.

        let file = directory.appendingPathComponent("userPlaylists.v1.json")
        try Data("garbage".utf8).write(to: file)

        let recovered = store.load()
        #expect(recovered.map(\.name) == ["Precious"])
    }

    @Test func emptyDirectoryLoadsNothing() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.load().isEmpty)
    }
}

// MARK: - Library scanning

@MainActor
struct LibraryScannerTests {

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func enumerationKeepsOnlyAudioFiles() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let sub = folder.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for name in ["a.mp3", "b.M4A", "notes.txt", ".hidden.mp3"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        try Data("x".utf8).write(to: sub.appendingPathComponent("c.flac"))

        let names = LibraryScanner.enumerateAudioFiles(in: folder).map { $0.url.lastPathComponent }.sorted()
        #expect(names == ["a.mp3", "b.M4A", "c.flac"])
    }

    @Test func unchangedFilesReuseTheirSavedSongWithoutBeingParsed() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let indexURL = folder.appendingPathComponent("index.json")

        // Not real audio: parsing it would fail and drop the song, so getting it back proves the
        // saved entry was used instead.
        let fileURL = folder.appendingPathComponent("fake.mp3")
        try Data("not really audio".utf8).write(to: fileURL)
        let file = try #require(LibraryScanner.enumerateAudioFiles(in: folder).first)

        let cached = Song(url: file.url, title: "From Index", artist: "A", album: "B", genre: "G")
        var index = LibraryIndex()
        index.entries[file.url.path] = .init(modified: file.modified, size: file.size, changed: file.changed, song: cached)
        index.save(to: indexURL)

        let songs = await LibraryScanner.scan(folderURL: folder, indexURL: indexURL)
        #expect(songs.map(\.title) == ["From Index"])
    }

    @Test func changedFilesAreNotServedFromTheIndex() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let indexURL = folder.appendingPathComponent("index.json")

        let fileURL = folder.appendingPathComponent("fake.mp3")
        try Data("not really audio".utf8).write(to: fileURL)
        let file = try #require(LibraryScanner.enumerateAudioFiles(in: folder).first)

        // The saved fingerprint doesn't match the file, so the entry is stale and the (unparseable)
        // file is re-read and dropped rather than the old title being returned.
        let cached = Song(url: file.url, title: "Stale", artist: "A", album: "B", genre: "G")
        var index = LibraryIndex()
        index.entries[file.url.path] = .init(modified: file.modified - 100, size: file.size, changed: file.changed, song: cached)
        index.save(to: indexURL)

        let songs = await LibraryScanner.scan(folderURL: folder, indexURL: indexURL)
        #expect(songs.isEmpty)
    }

    @Test func deletedFilesAreDroppedFromTheIndex() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let indexURL = folder.appendingPathComponent("index.json")

        let gone = Song(url: folder.appendingPathComponent("gone.mp3"), title: "Gone", artist: "A", album: "B", genre: "G")
        var index = LibraryIndex()
        index.entries[gone.url.path] = .init(modified: 1, size: 1, song: gone)
        index.save(to: indexURL)

        let songs = await LibraryScanner.scan(folderURL: folder, indexURL: indexURL)
        #expect(songs.isEmpty)
        #expect(LibraryIndex.load(from: indexURL).entries.isEmpty)
    }

    @Test func missingOrCorruptIndexIsJustAnEmptyIndex() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(LibraryIndex.load(from: folder.appendingPathComponent("nope.json")).entries.isEmpty)

        let bad = folder.appendingPathComponent("bad.json")
        try Data("{{{".utf8).write(to: bad)
        #expect(LibraryIndex.load(from: bad).entries.isEmpty)
    }
}

// MARK: - Change detection & artwork cleanup

@MainActor
struct ChangeDetectionTests {

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChangeDetectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func editThatKeepsModificationDateAndSizeIsStillDetectedByChangeTime() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let fileURL = folder.appendingPathComponent("fake.mp3")
        try Data("aaaa".utf8).write(to: fileURL)
        let before = try #require(LibraryScanner.enumerateAudioFiles(in: folder).first)
        let song = Song(url: before.url, title: "Before", artist: "A", album: "B", genre: "G")
        let entry = LibraryIndex.Entry(modified: before.modified, size: before.size, changed: before.changed, song: song)
        #expect(LibraryScanner.isCurrent(entry, for: before))

        // Rewrite with same-size content, then put the modification date back, as `cp -p` would.
        let originalDate = try #require(try fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try await Task.sleep(for: .milliseconds(20))
        try Data("bbbb".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: fileURL.path)

        let after = try #require(LibraryScanner.enumerateAudioFiles(in: folder).first)
        #expect(after.size == before.size)
        #expect(abs(after.modified - before.modified) < 0.001)   // Date and size look untouched...
        #expect(after.changed > before.changed)                  // ...but the change time moved.

        // Even if the modification date had been restored exactly, the change time alone makes the
        // saved entry stale.
        let lookalike = LibraryIndex.Entry(modified: after.modified, size: after.size, changed: before.changed, song: song)
        #expect(!LibraryScanner.isCurrent(lookalike, for: after))
        let current = LibraryIndex.Entry(modified: after.modified, size: after.size, changed: after.changed, song: song)
        #expect(LibraryScanner.isCurrent(current, for: after))
    }

    @Test func indexIsKeptWhenTheMusicFolderIsMissing() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let indexURL = folder.appendingPathComponent("index.json")

        let missing = folder.appendingPathComponent("UnmountedDrive", isDirectory: true)
        let song = Song(url: missing.appendingPathComponent("a.mp3"), title: "Kept", artist: "A", album: "B", genre: "G")
        var index = LibraryIndex()
        index.entries[song.url.path] = .init(modified: 1, size: 1, song: song)
        index.save(to: indexURL)

        let songs = await LibraryScanner.scan(folderURL: missing, indexURL: indexURL)
        #expect(songs.isEmpty)
        #expect(LibraryIndex.load(from: indexURL).entries.count == 1)
    }

    @Test func pruneDeletesOnlyOldUnreferencedArtwork() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkPruneTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ArtworkStore(directory: directory)

        let used = store.store(Data("used".utf8))
        let orphanOld = store.store(Data("orphan-old".utf8))
        let orphanNew = store.store(Data("orphan-new".utf8))
        let usedOld = store.store(Data("used-old".utf8))

        // Age two of the files past the grace period.
        let longAgo = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        for key in [orphanOld, usedOld] {
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: directory.appendingPathComponent(key).path)
        }

        let removed = store.prune(keeping: [used, usedOld])
        #expect(removed == 1)
        #expect(!store.contains(orphanOld))   // old and unreferenced: deleted
        #expect(store.contains(orphanNew))    // unreferenced but recent: kept
        #expect(store.contains(used))         // referenced: kept
        #expect(store.contains(usedOld))      // old but referenced: kept
    }
}
