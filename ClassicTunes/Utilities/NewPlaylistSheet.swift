import SwiftUI

struct NewPlaylistSheet: View {
    @Binding var playlists: [Playlist]
    @Environment(\.dismiss) private var dismiss
    @State private var playlistName = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("newPlaylist.title")
                .font(.title2)
                .bold()
            
            VStack(alignment: .leading, spacing: 5) {
                Text("newPlaylist.nameLabel")
                    .font(.headline)
                TextField("newPlaylist.namePlaceholder", text: $playlistName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            HStack {
                Spacer()
                Button("newPlaylist.cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("newPlaylist.create") {
                    createPlaylist()
                }
                .disabled(playlistName.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }
    
    private func createPlaylist() {
        let newPlaylist = Playlist(name: playlistName, songs: [])
        playlists.append(newPlaylist)
        PlaylistStore.shared.save(playlists)
        dismiss()
    }
}
