import Foundation
import SwiftUI
import Combine

// An observable data controller responsible for managing, filtering, and mutating user-created playlists.
class PlaylistManager: ObservableObject {
    
    // The reactive collection of custom user-created playlists exposed directly to view components.
    @Published var userPlaylists: [Playlist] = []

    // Initializes a new manager instance and kicks off an initial pull from long-term storage registers.
    init() {
        loadPlaylists()
    }

    // Pulls raw playlists from persistent storage and filters out immutable default system elements.
    func loadPlaylists() {
        // Load only custom (non-system) playlists from file-based store
        let loaded = PlaylistStore.shared.load()
        userPlaylists = loaded.filter { !$0.isSystem }
    }

    // Commits the current filtered selection of custom user playlists to active disk storage registers.
    func savePlaylists() {
        // Persist only custom playlists
        PlaylistStore.shared.save(userPlaylists.filter { !$0.isSystem })
    }

    // Appends a specific track to an existing user playlist if it is not already present, then forces a disk save.
    //
    // - Parameters:
    //   - song: The source `Song` model structure to add.
    //   - playlist: The target `Playlist` entity destination.
    func addSong(_ song: Song, to playlist: Playlist) {
        guard var target = userPlaylists.first(where: { $0.id == playlist.id }) else { return }
        guard !target.songs.contains(where: { $0.id == song.id }) else { return }
        target.songs.append(song)
        if let index = userPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            userPlaylists[index] = target
            savePlaylists()
        }
    }

    // Allocates an empty custom playlist container with a specified title wrapper and commits it to disk storage.
    //
    // - Parameter name: The user-provided string title used to describe the collection.
    func createPlaylist(named name: String) {
        let newPlaylist = Playlist(name: name, songs: [])
        userPlaylists.append(newPlaylist)
        savePlaylists()
    }

    // Erases a custom playlist matching the provided identity signature across current reactive layers and updates disk arrays.
    //
    // - Parameter playlist: The targeted custom data structure marked for removal.
    func deletePlaylist(_ playlist: Playlist) {
        userPlaylists.removeAll { $0.id == playlist.id }
        savePlaylists()
    }
}
