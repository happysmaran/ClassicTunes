import SwiftUI

struct SidebarView: View {
    var playlists: [Playlist]
    @Binding var userPlaylists: [Playlist]
    @Binding var selectedPlaylistID: UUID?
    @Binding var showNewPlaylistSheet: Bool
    @Binding var libraryActive: Bool

    private var allPlaylists: [Playlist] {
        userPlaylists + playlists.filter { $0.isSystem }
    }

    var body: some View {
        List {
            Section("LIBRARY") {
                Label("Music", systemImage: "music.note")
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedPlaylistID = nil
                        libraryActive = true
                    }
                Label("Movies", systemImage: "film")
                Label("TV Shows", systemImage: "tv")
                Label("Podcasts", systemImage: "mic")
                Label("Radio", systemImage: "radio")
            }
            
            Section("STORE") {
                Label("iTunes Store", systemImage: "bag")
            }
            
            Section("PLAYLISTS") {
                ForEach(allPlaylists) { playlist in
                    HStack {
                        Text(playlist.name)
                        Spacer()
                        if !playlist.isSystem {
                            Button(action: {
                                if let index = userPlaylists.firstIndex(where: { $0.id == playlist.id }) {
                                    userPlaylists.remove(at: index)
                                    savePlaylistsToUserDefaults(userPlaylists)
                                }
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedPlaylistID = playlist.id
                        libraryActive = false
                    }
                }
                
                Button(action: {
                    showNewPlaylistSheet = true
                }) {
                    Label("New Playlist", systemImage: "plus")
                }
            }
        }
        .listStyle(SidebarListStyle())
        .background(Color.itunesSidebar)
        .foregroundColor(.primary)
    }
}
