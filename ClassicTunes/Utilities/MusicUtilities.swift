import SwiftUI
import AVKit

extension Color {
    static let itunesSidebar = Color(NSColor(calibratedWhite: 0.9, alpha: 1.0))
    static let itunesWindowBG = Color(NSColor(calibratedWhite: 0.2, alpha: 1.0))
    static let itunesHeaderBG = Color(red: 0.3, green: 0.3, blue: 0.3)
    static let itunesSelected = Color(red: 0.32, green: 0.44, blue: 0.76)
}

// Utility functions
func loadSongs(from folderURL: URL) -> [Song] {
    let allowedExtensions = ["mp3", "m4a", "aac", "wav", "flac"]
    let fileManager = FileManager.default
    var loadedSongs: [Song] = []

    guard let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: nil) else {
        print("Could not create enumerator")
        return []
    }

    for case let fileURL as URL in enumerator {
        guard allowedExtensions.contains(fileURL.pathExtension.lowercased()) else {
            continue
        }

        let asset = AVURLAsset(url: fileURL)
        var title = fileURL.deletingPathExtension().lastPathComponent
        var artist = "Unknown Artist"
        var album = "Unknown Album"
        var year = "-"
        var genre = "Unknown Genre"
        var artworkData: Data? = nil
        
        // print(asset.commonMetadata)

        for item in asset.commonMetadata {
            switch item.commonKey?.rawValue {
            case "title":
                title = item.value as? String ?? title
            case "artist":
                artist = item.value as? String ?? artist
            case "albumName":
                album = item.value as? String ?? album
            case "type":
                genre = item.value as? String ?? genre
            case "artwork":
                artworkData = item.value as? Data
            default:
                break
            }
        }

        let song = Song(url: fileURL, title: title, artist: artist, album: album, year: year, genre: genre, artworkData: artworkData)
        loadedSongs.append(song)
    }

    return loadedSongs
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

func loadPlaylistsFromUserDefaults() -> [Playlist] {
    guard let data = UserDefaults.standard.data(forKey: "playlists") else {
        return []
    }
    let decoder = JSONDecoder()
    do {
        let playlists = try decoder.decode([Playlist].self, from: data)
        return playlists
    } catch {
        print("Error decoding playlists: \(error)")
        return []
    }
}

func savePlaylistsToUserDefaults(_ playlists: [Playlist]) {
    let encoder = JSONEncoder()
    do {
        let data = try encoder.encode(playlists)
        UserDefaults.standard.set(data, forKey: "playlists")
    } catch {
        print("Error encoding playlists: \(error)")
    }
}

// MARK: - Play Count & Play History Utilities

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

// MARK: - System Playlist Generators

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

// MARK: - Playlist loading & saving utilities

func loadUserPlaylists() -> [Playlist] {
    // Only custom playlists, not system ones
    return loadPlaylistsFromUserDefaults().filter { !$0.isSystem }
}

func saveUserPlaylists(_ playlists: [Playlist]) {
    // Only save custom playlists
    savePlaylistsToUserDefaults(playlists.filter { !$0.isSystem })
}

