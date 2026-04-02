import SwiftUI
import AVKit

extension Color {
    static let itunesSidebar = Color(NSColor(calibratedWhite: 0.9, alpha: 1.0))
    static let itunesWindowBG = Color(NSColor(calibratedWhite: 0.2, alpha: 1.0))
    static let itunesHeaderBG = Color(red: 0.3, green: 0.3, blue: 0.3)
    static let itunesSelected = Color(red: 0.32, green: 0.44, blue: 0.76)
}

// Utility functions
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

func getArtwork(from url: URL) -> NSImage? {
    let asset = AVURLAsset(url: url)
    let metadata = asset.commonMetadata

    for item in metadata {
        if item.commonKey?.rawValue == "artwork",
           let data = item.value as? Data,
           let image = NSImage(data: data) {
            return image
        }
    }
    return nil
}

let playHistoryKey = "playHistory"
let playCountKey = "playCounts"

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

func getPlayCount(for song: Song) -> Int {
    let playCounts = UserDefaults.standard.dictionary(forKey: playCountKey) as? [String: Int] ?? [:]
    return playCounts[song.id.uuidString] ?? 0
}

func getPlayHistory() -> [String] {
    UserDefaults.standard.stringArray(forKey: playHistoryKey) ?? []
}

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

// Returns a version of the string suitable for sorting by ignoring leading articles, whitespace, and non-alphanumerics
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
