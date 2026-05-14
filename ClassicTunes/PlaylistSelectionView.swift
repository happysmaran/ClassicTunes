import SwiftUI

struct PlaylistSelectionView: View {
    let song: Song
    let onAddToPlaylist: (Playlist) -> Void
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var playlistManager: PlaylistManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("playlistSelection.title")
                .font(.headline)
                .padding(.top)
            
            Text("playlistSelection.message")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if playlistManager.userPlaylists.isEmpty {
                Text("playlistSelection.message")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                List(playlistManager.userPlaylists) { playlist in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(playlist.name)
                                .font(.body)
                            Text("playlistSelection.songCount")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if playlist.songs.contains(where: { $0.id == song.id }) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onAddToPlaylist(playlist)
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            
            HStack {
                Spacer()
                Button("playlistSelection.cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 300, minHeight: 300)
    }
}
