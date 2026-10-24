import Foundation

// Represents a collection of songs within the application, such as user-created playlists or default system views.
struct Playlist: Identifiable, Codable {
    
    // The unique identifier for the playlist.
    let id: UUID
    
    // The display name of the playlist.
    var name: String
    
    // The collection of songs contained within this playlist.
    var songs: [Song]
    
    // A flag indicating whether this is a default, un-deletable system playlist (e.g., "Library", "Purchased").
    var isSystem: Bool = false
    
    // The rules defining a smart playlist, or `nil` for a regular playlist. Smart playlists don't
    // store their songs; `songs` is recomputed from the library via `resolved(against:)`.
    var smartRules: SmartPlaylistRules? = nil
    
    // Initializes a new Playlist instance.
    //
    // - Parameters:
    //   - id: A unique identifier for the playlist. Defaults to a new UUID.
    //   - name: The visible title of the playlist.
    //   - songs: An initial array of `Song` objects to include in the playlist.
    //   - isSystem: Explicitly marks if this playlist is a core system playlist. Defaults to `false`.
    //   - smartRules: Rules making this a smart playlist. Defaults to `nil` (regular playlist).
    init(id: UUID = UUID(), name: String, songs: [Song], isSystem: Bool = false, smartRules: SmartPlaylistRules? = nil) {
        self.id = id
        self.name = name
        self.songs = songs
        self.isSystem = isSystem
        self.smartRules = smartRules
    }
}
