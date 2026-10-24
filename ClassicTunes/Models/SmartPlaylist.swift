import Foundation

// A song attribute that a smart playlist rule can test.
enum SmartRuleField: String, Codable, CaseIterable, Identifiable {
    case title, artist, album, albumArtist, genre, composer, grouping, comment
    case year, playCount, bpm, trackNumber, discNumber, duration

    var id: String { rawValue }

    // Whether the field is compared numerically (otherwise it is compared as text).
    var isNumeric: Bool {
        switch self {
        case .year, .playCount, .bpm, .trackNumber, .discNumber, .duration: return true
        default: return false
        }
    }

    var localizedName: String {
        NSLocalizedString("smartPlaylist.field.\(rawValue)", comment: "smart playlist field")
    }

    // The operators that make sense for this field.
    var availableOperators: [SmartRuleOperator] {
        isNumeric ? SmartRuleOperator.numericOperators : SmartRuleOperator.textOperators
    }
}

// How a rule compares a song attribute to the rule's value.
enum SmartRuleOperator: String, Codable, CaseIterable, Identifiable {
    // Text
    case contains, doesNotContain, `is`, isNot, startsWith, endsWith
    // Numeric
    case equals, notEquals, greaterThan, lessThan, inRange

    var id: String { rawValue }

    static let textOperators: [SmartRuleOperator] = [.contains, .doesNotContain, .is, .isNot, .startsWith, .endsWith]
    static let numericOperators: [SmartRuleOperator] = [.equals, .notEquals, .greaterThan, .lessThan, .inRange]

    var localizedName: String {
        NSLocalizedString("smartPlaylist.operator.\(rawValue)", comment: "smart playlist operator")
    }
}

// A single "field operator value" condition.
struct SmartRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var field: SmartRuleField = .artist
    var op: SmartRuleOperator = .contains
    var value: String = ""
    // Upper bound, only used by the `inRange` operator.
    var secondValue: String = ""

    // Whether the rule has enough input to be evaluated. Incomplete rules are ignored.
    var isComplete: Bool {
        let first = value.trimmingCharacters(in: .whitespaces)
        if first.isEmpty { return false }
        if op == .inRange {
            return !secondValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    func matches(_ song: Song) -> Bool {
        field.isNumeric ? matchesNumber(song) : matchesText(song)
    }

    private func textValue(of song: Song) -> String {
        switch field {
        case .title: return song.title
        case .artist: return song.artist
        case .album: return song.album
        case .albumArtist: return song.albumArtist ?? ""
        case .genre: return song.genre
        case .composer: return song.composer ?? ""
        case .grouping: return song.grouping ?? ""
        case .comment: return song.comment ?? ""
        default: return ""
        }
    }

    private func numberValue(of song: Song) -> Double? {
        switch field {
        case .year: return song.year.flatMap { Int($0.prefix(4)) }.map(Double.init)
        case .playCount: return Double(song.playCount)
        case .bpm: return song.bpm.map(Double.init)
        case .trackNumber: return song.trackNumber.map(Double.init)
        case .discNumber: return song.discNumber.map(Double.init)
        case .duration: return song.duration
        default: return nil
        }
    }

    private func matchesText(_ song: Song) -> Bool {
        let actual = textValue(of: song)
        let wanted = value.trimmingCharacters(in: .whitespaces)
        switch op {
        case .contains: return actual.localizedCaseInsensitiveContains(wanted)
        case .doesNotContain: return !actual.localizedCaseInsensitiveContains(wanted)
        case .is: return actual.localizedCaseInsensitiveCompare(wanted) == .orderedSame
        case .isNot: return actual.localizedCaseInsensitiveCompare(wanted) != .orderedSame
        case .startsWith: return actual.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
        case .endsWith: return actual.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive, .backwards, .anchored]) != nil
        default: return false
        }
    }

    private func matchesNumber(_ song: Song) -> Bool {
        guard let wanted = Double(value.trimmingCharacters(in: .whitespaces)) else { return false }
        // Songs missing the attribute only match "not equal".
        guard let actual = numberValue(of: song) else { return op == .notEquals }
        switch op {
        case .equals: return actual == wanted
        case .notEquals: return actual != wanted
        case .greaterThan: return actual > wanted
        case .lessThan: return actual < wanted
        case .inRange:
            guard let upper = Double(secondValue.trimmingCharacters(in: .whitespaces)) else { return false }
            return actual >= min(wanted, upper) && actual <= max(wanted, upper)
        default: return false
        }
    }
}

// How a limited smart playlist chooses which songs to keep.
enum SmartLimitSelection: String, Codable, CaseIterable, Identifiable {
    case random, mostPlayed, leastPlayed, title, artist, album, newestYear, oldestYear

    var id: String { rawValue }

    var localizedName: String {
        NSLocalizedString("smartPlaylist.selection.\(rawValue)", comment: "smart playlist limit selection")
    }
}

// The full definition of a smart playlist: its rules plus optional limit.
struct SmartPlaylistRules: Codable, Hashable {
    var rules: [SmartRule] = [SmartRule()]
    // When true every rule must match; otherwise any one rule is enough.
    var matchAll: Bool = true
    var limitEnabled: Bool = false
    var limit: Int = 25
    var selection: SmartLimitSelection = .mostPlayed

    // Evaluates the rules against the library and applies the optional limit.
    func songs(from library: [Song]) -> [Song] {
        let active = rules.filter { $0.isComplete }
        var seen = Set<UUID>()
        var result = library.filter { song in
            guard seen.insert(song.id).inserted else { return false }
            guard !active.isEmpty else { return false }
            return matchAll ? active.allSatisfy { $0.matches(song) } : active.contains { $0.matches(song) }
        }
        guard limitEnabled else { return result }

        switch selection {
        case .random: result.shuffle()
        case .mostPlayed: result.sort { $0.playCount > $1.playCount }
        case .leastPlayed: result.sort { $0.playCount < $1.playCount }
        case .title: result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: result.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .album: result.sort { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        case .newestYear: result.sort { (Int($0.year?.prefix(4) ?? "") ?? 0) > (Int($1.year?.prefix(4) ?? "") ?? 0) }
        case .oldestYear: result.sort { (Int($0.year?.prefix(4) ?? "") ?? .max) < (Int($1.year?.prefix(4) ?? "") ?? .max) }
        }
        return Array(result.prefix(max(limit, 0)))
    }
}

extension Playlist {
    var isSmart: Bool { smartRules != nil }

    // Returns the playlist with its songs filled in from the library when it is a smart playlist.
    // Regular and system playlists are returned unchanged, so callers (display, M3U export) treat
    // every playlist type the same way.
    func resolved(against library: [Song]) -> Playlist {
        guard let rules = smartRules else { return self }
        var copy = self
        copy.songs = rules.songs(from: library)
        return copy
    }
}
