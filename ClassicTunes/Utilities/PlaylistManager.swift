import Foundation
import SwiftUI
import Combine

class PlaylistManager: ObservableObject {
    @Published var userPlaylists: [Playlist] = []
    
    init() {
        loadPlaylists()
    }
    
    func loadPlaylists() {
        userPlaylists = loadUserPlaylists()
    }
    
    func savePlaylists() {
        saveUserPlaylists(userPlaylists)
    }
    
    func addSong(_ song: Song, to playlist: Playlist) {
        guard var targetPlaylist = userPlaylists.first(where: { $0.id == playlist.id }),
              !targetPlaylist.songs.contains(where: { $0.id == song.id }) else {
            return // Song already in playlist or playlist not found
        }
        
        targetPlaylist.songs.append(song)
        
        if let index = userPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            userPlaylists[index] = targetPlaylist
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
