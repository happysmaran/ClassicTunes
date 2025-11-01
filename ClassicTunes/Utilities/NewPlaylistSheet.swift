import SwiftUI

struct NewPlaylistSheet: View {
    @Binding var playlists: [Playlist]
    @Environment(\.dismiss) private var dismiss
    @State private var playlistName = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Playlist")
                .font(.title2)
                .bold()
            
            VStack(alignment: .leading, spacing: 5) {
                Text("Name")
                    .font(.headline)
                TextField("Playlist name", text: $playlistName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Create") {
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
        savePlaylistsToUserDefaults(playlists)
        dismiss()
    }
}
