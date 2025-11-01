import Foundation
import AVKit

struct Song: Identifiable, Codable, Hashable {
    let id: UUID
    let url: URL
    let title: String
    let artist: String
    let album: String
    let genre: String
    var playCount: Int = 0
    var artworkData: Data? = nil  // Store artwork data directly
    
    init(id: UUID = UUID(), url: URL, title: String, artist: String, album: String, year: String, genre: String, playCount: Int = 0, artworkData: Data? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.playCount = playCount
        self.artworkData = artworkData
    }
    
    // Computed property to get artwork as NSImage
    var artworkImage: NSImage? {
        guard let data = artworkData else { return nil }
        return NSImage(data: data)
    }
}

