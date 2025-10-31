import Foundation

struct Playlist: Identifiable, Codable {
    let id: UUID
    var name: String
    var songs: [Song]
    var isSystem: Bool = false
    
    init(id: UUID = UUID(), name: String, songs: [Song], isSystem: Bool = false) {
        self.id = id
        self.name = name
        self.songs = songs
        self.isSystem = isSystem
    }
}