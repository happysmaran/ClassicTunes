import SwiftUI
import AVFoundation

// MARK: - Color Extensions

extension Color {
    // The legacy brushed-slate background hue for the primary sidebar[span_2](start_span)[span_2](end_span).
    static let itunesSidebar = Color(NSColor(calibratedWhite: 0.9, alpha: 1.0))
    
    // The deep theme background tone used for frame borders or dark modes[span_3](start_span)[span_3](end_span).
    static let itunesWindowBG = Color(NSColor(calibratedWhite: 0.2, alpha: 1.0))
    
    // The exact mid-gray hue capturing the classic header/status console bar[span_4](start_span)[span_4](end_span).
    static let itunesHeaderBG = Color(red: 0.3, green: 0.3, blue: 0.3)
    
    // The quintessential retro blue accent used for highlighted source items and rows[span_5](start_span)[span_5](end_span).
    static let itunesSelected = Color(red: 0.32, green: 0.44, blue: 0.76)
}

// MARK: - Song Processing Infrastructure

// Asynchronously crawls a local folder directory to import and build supported music tracks.
//
// Backed by `LibraryScanner`: files unchanged since the last scan reuse their saved entry in the
// library index, and only new or modified files are parsed (a few at a time) on background threads.
//
// - Parameter folderURL: The file system target directory containing the source files.
// - Returns: A populated array of structurally parsed `Song` models.
func loadSongs(from folderURL: URL) async -> [Song] {
    await LibraryScanner.scan(folderURL: folderURL)
}

// Discovers and decodes embedded audio metadata block graphics to provide a standalone album view[span_10](start_span)[span_10](end_span).
//
// - Parameter url: The localized track file system link reference[span_11](start_span)[span_11](end_span).
// - Returns: An initialized `NSImage` graphic object if metadata images are present[span_12](start_span)[span_12](end_span).
func getArtwork(from url: URL) async -> NSImage? {
    let asset = AVURLAsset(url: url)
    guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
    for item in metadata {
        if item.commonKey == .commonKeyArtwork,
           let data = try? await item.load(.value) as? Data,
           let image = NSImage(data: data) {
            return image
        }
    }
    return nil
}

// MARK: - Playback History & Analytics Storage

// Storage reference key holding raw playback order histories[span_13](start_span)[span_13](end_span).
let playHistoryKey = "playHistory"

// Storage reference key holding aggregate track play counts[span_14](start_span)[span_14](end_span).
let playCountKey = "playCounts"

// Increments historical track records and inserts the track sequence into local user preferences[span_15](start_span)[span_15](end_span).
//
// - Parameter song: The current operational target track completing its playback stream loop[span_16](start_span)[span_16](end_span).
func incrementPlayCount(for song: Song) {
    var playCounts = UserDefaults.standard.dictionary(forKey: playCountKey) as? [String: Int] ?? [:]
    let songID = song.id.uuidString
    playCounts[songID, default: 0] += 1
    UserDefaults.standard.set(playCounts, forKey: playCountKey)

    // Track play history
    var history = UserDefaults.standard.stringArray(forKey: playHistoryKey) ?? []
    history.insert(songID, at: 0)
    if history.count > 1000 { history = Array(history.prefix(1000)) }
    UserDefaults.standard.set(history, forKey: playHistoryKey)

    recordLastPlayed(for: song)
}

// Every recorded play count, keyed by song ID, read in one go.
//
// `getPlayCount(for:)` loads the whole counts table from `UserDefaults` on every call, so asking for
// each song's count in a loop is quadratic in the library size. Callers that need many counts
// should read this once instead.
func getAllPlayCounts() -> [UUID: Int] {
    let stored = UserDefaults.standard.dictionary(forKey: playCountKey) as? [String: Int] ?? [:]
    var counts: [UUID: Int] = [:]
    counts.reserveCapacity(stored.count)
    for (key, value) in stored {
        if let id = UUID(uuidString: key) { counts[id] = value }
    }
    return counts
}

// Evaluates absolute historical loop metrics for a specified data model entity[span_17](start_span)[span_17](end_span).
//
// - Parameter song: Target element model reference[span_18](start_span)[span_18](end_span).
// - Returns: Total structural execution instances stored natively in long-term registers[span_19](start_span)[span_19](end_span).
func getPlayCount(for song: Song) -> Int {
    let playCounts = UserDefaults.standard.dictionary(forKey: playCountKey) as? [String: Int] ?? [:]
    return playCounts[song.id.uuidString] ?? 0
}

// Retrieves the raw collection index histories tracking global track selections[span_20](start_span)[span_20](end_span).
func getPlayHistory() -> [String] {
    UserDefaults.standard.stringArray(forKey: playHistoryKey) ?? []
}

// Storage reference key holding per-track last-played timestamps.
let lastPlayedKey = "lastPlayed"

// Records the current moment as the most recent playback timestamp for a track.
//
// - Parameter song: The track that just started or finished playing.
func recordLastPlayed(for song: Song, date: Date = Date()) {
    var lastPlayed = UserDefaults.standard.dictionary(forKey: lastPlayedKey) as? [String: Double] ?? [:]
    lastPlayed[song.id.uuidString] = date.timeIntervalSince1970
    UserDefaults.standard.set(lastPlayed, forKey: lastPlayedKey)
}

// Resolves the most recent playback timestamp recorded for a track, if any.
//
// - Parameter song: Target track to query.
// - Returns: The date the track was last played, or `nil` if it has never played.
func getLastPlayed(for song: Song) -> Date? {
    let lastPlayed = UserDefaults.standard.dictionary(forKey: lastPlayedKey) as? [String: Double] ?? [:]
    guard let interval = lastPlayed[song.id.uuidString] else { return nil }
    return Date(timeIntervalSince1970: interval)
}

// MARK: - Smart Playlist Generation Engine

// Programmatically builds a temporary smart-playlist collecting recent audio selections without duplicates[span_21](start_span)[span_21](end_span).
//
// - Parameters:
//   - allSongs: The current total global database inventory collection[span_22](start_span)[span_22](end_span).
//   - maxCount: Bounds definition constraint capping the maximum results array length. Defaults to `25`[span_23](start_span)[span_23](end_span).
// - Returns: A dedicated system-flagged structural collection array wrapper object[span_24](start_span)[span_24](end_span).
func generateRecentlyPlayedPlaylist(from allSongs: [Song], maxCount: Int = 25) -> Playlist {
    let history = getPlayHistory().compactMap { UUID(uuidString: $0) }

    // One pass over the library picks out just the songs the history mentions, instead of
    // searching the whole library once per history entry.
    let wanted = Set(history)
    var byID: [UUID: Song] = [:]
    for song in allSongs where wanted.contains(song.id) {
        byID[song.id] = song
    }

    var seen = Set<UUID>()
    var recentSongs: [Song] = []
    for songID in history {
        if seen.contains(songID) { continue }
        if let song = byID[songID] {
            recentSongs.append(song)
            seen.insert(songID)
            if recentSongs.count == maxCount { break }
        }
    }
    return Playlist(name: "Recently Played", songs: recentSongs, isSystem: true)
}

// Filters and balances historical library instances to build a localized high-frequency playlist collection[span_25](start_span)[span_25](end_span).
//
// Sorts track models by total play count, breaking ties alphabetically by title string characters[span_26](start_span)[span_26](end_span).
//
// - Parameters:
//   - allSongs: Global data library array pool[span_27](start_span)[span_27](end_span).
//   - maxCount: Numerical cutoff range sizing limits. Defaults to `25`[span_28](start_span)[span_28](end_span).
// - Returns: An immutable system-designated structural group representation[span_29](start_span)[span_29](end_span).
func generateTopPlayedPlaylist(from allSongs: [Song], maxCount: Int = 25) -> Playlist {
    let playCounts = getAllPlayCounts()

    // Highest count first, ties broken alphabetically by title.
    func ranksBefore(_ a: (song: Song, count: Int), _ b: (song: Song, count: Int)) -> Bool {
        if a.count == b.count { return a.song.title < b.song.title }
        return a.count > b.count
    }

    // Only `maxCount` songs are kept, so track the current best in a short sorted list instead of
    // sorting the entire library (most of which has never been played) on every call.
    var best: [(song: Song, count: Int)] = []
    guard maxCount > 0 else { return Playlist(name: "Top 25 Most Played", songs: [], isSystem: true) }
    for song in allSongs {
        let candidate = (song: song, count: playCounts[song.id] ?? 0)
        if best.count == maxCount, let last = best.last, !ranksBefore(candidate, last) { continue }
        let insertAt = best.firstIndex(where: { ranksBefore(candidate, $0) }) ?? best.count
        best.insert(candidate, at: insertAt)
        if best.count > maxCount { best.removeLast() }
    }
    return Playlist(name: "Top 25 Most Played", songs: best.map(\.song), isSystem: true)
}

// MARK: - String Parsing Mechanics

// Re-maps a string into an idealized variant designed for uniform sorting, masking articles and edge symbols[span_30](start_span)[span_30](end_span).
//
// Strips out leading English articles ("The", "A", "An") and isolates trailing alphanumeric content
// so that artists like "The Beatles" register accurately inside standard library "B" segments[span_31](start_span)[span_31](end_span).
//
// - Parameter value: Original input string source[span_32](start_span)[span_32](end_span).
// - Returns: Cleaned processing string used natively for sequence validation tasks[span_33](start_span)[span_33](end_span).
public func normalizedSortKey(_ value: String) -> String {
    var working = value.trimmingCharacters(in: .whitespacesAndNewlines)

    if let firstAlnumIndex = working.firstIndex(where: { $0.isLetter || $0.isNumber }) {
        working = String(working[firstAlnumIndex...])
    } else {
        return working
    }

    let lower = working.lowercased()
    let articles = ["the ", "a ", "an "]
    for article in articles {
        if lower.hasPrefix(article) {
            let dropCount = article.count
            working = String(working.dropFirst(dropCount)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
    }

    return working
}
