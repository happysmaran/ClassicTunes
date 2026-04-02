import Foundation
import SwiftUI
import Combine

class PlaylistManager: ObservableObject {
    @Published var userPlaylists: [Playlist] = []

    init() {
        loadPlaylists()
    }

    func loadPlaylists() {
        // Load only custom (non-system) playlists from file-based store
        let loaded = PlaylistStore.shared.load()
        userPlaylists = loaded.filter { !$0.isSystem }
    }

    func savePlaylists() {
        // Persist only custom playlists
        PlaylistStore.shared.save(userPlaylists.filter { !$0.isSystem })
    }

    func addSong(_ song: Song, to playlist: Playlist) {
        guard var target = userPlaylists.first(where: { $0.id == playlist.id }) else { return }
        guard !target.songs.contains(where: { $0.id == song.id }) else { return }
        target.songs.append(song)
        if let index = userPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            userPlaylists[index] = target
            savePlaylists()
        }
    }

    func createPlaylist(named name: String) {
        let newPlaylist = Playlist(name: name, songs: [])
        userPlaylists.append(newPlaylist)
        savePlaylists()
    }

    func deletePlaylist(_ playlist: Playlist) {
        userPlaylists.removeAll { $0.id == playlist.id }
        savePlaylists()
    }
}
