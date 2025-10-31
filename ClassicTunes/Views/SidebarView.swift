import SwiftUI

struct Sidebar: View {
    @Binding var playlists: [Playlist]
    @Binding var selectedPlaylistID: UUID?
    @Binding var showNewPlaylistSheet: Bool

    var body: some View {
        List {
            Section("LIBRARY") {
                Label("Music", systemImage: "music.note")
                Label("Movies", systemImage: "film")
                Label("TV Shows", systemImage: "tv")
                Label("Podcasts", systemImage: "mic")
                Label("Radio", systemImage: "radio")
            }
            
            Section("STORE") {
                Label("iTunes Store", systemImage: "bag")
            }
            
            Section("PLAYLISTS") {
                ForEach(playlists) { playlist in
                    HStack {
                        Text(playlist.name)
                        Spacer()
                        if !playlist.isSystem {
                            Button(action: {
                                if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                                    playlists.remove(at: index)
                                    savePlaylistsToUserDefaults(playlists)
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