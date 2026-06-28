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

// Asynchronously crawls a local folder directory to import and build supported music tracks[span_6](start_span)[span_6](end_span).
//
// Implemented using a concurrent `withTaskGroup` pipeline to process independent file tags
// safely on background worker threads without bottlenecking the main runtime loop[span_7](start_span)[span_7](end_span).
//
// - Parameter folderURL: The file system target directory containing the source files[span_8](start_span)[span_8](end_span).
// - Returns: A populated array of structurally parsed `Song` models[span_9](start_span)[span_9](end_span).
func loadSongs(from folderURL: URL) async -> [Song] {
    let allowedExtensions = ["mp3", "m4a", "aac", "wav", "flac"]
    let fileManager = FileManager.default

    guard let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: nil) else {
        print("Could not create enumerator")
        return []
    }

    let fileURLs = enumerator
        .compactMap { $0 as? URL }
        .filter { allowedExtensions.contains($0.pathExtension.lowercased()) }

    return await withTaskGroup(of: Song?.self) { group in
        for fileURL in fileURLs {
            group.addTask {
                try? await Song.load(from: fileURL)
            }
        }
        var results: [Song] = []
        for await song in group {
            if let song { results.append(song) }
        }
        return results
    }
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

// MARK: - Smart Playlist Generation Engine

// Programmatically builds a temporary smart-playlist collecting recent audio selections without duplicates[span_21](start_span)[span_21](end_span).
//
// - Parameters:
//   - allSongs: The current total global database inventory collection[span_22](start_span)[span_22](end_span).
//   - maxCount: Bounds definition constraint capping the maximum results array length. Defaults to `25`[span_23](start_span)[span_23](end_span).
// - Returns: A dedicated system-flagged structural collection array wrapper object[span_24](start_span)[span_24](end_span).
func generateRecentlyPlayedPlaylist(from allSongs: [Song], maxCount: Int = 25) -> Playlist {
    let history = getPlayHistory()
    var seen = Set<String>()
    var recentSongs: [Song] = []
    for songID in history {
        if seen.contains(songID) { continue }
        if let song = allSongs.first(where: { $0.id.uuidString == songID }) {
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
    let playCounts = UserDefaults.standard.dictionary(forKey: playCountKey) as? [String: Int] ?? [:]
    let sortedSongs = allSongs.sorted { (s1, s2) -> Bool in
        let c1 = playCounts[s1.id.uuidString] ?? 0
        let c2 = playCounts[s2.id.uuidString] ?? 0
        if c1 == c2 { return s1.title < s2.title }
        return c1 > c2
    }
    let topSongs = Array(sortedSongs.prefix(maxCount))
    return Playlist(name: "Top 25 Most Played", songs: topSongs, isSystem: true)
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
