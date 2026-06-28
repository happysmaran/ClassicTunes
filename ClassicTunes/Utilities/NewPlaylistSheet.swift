import SwiftUI

// A modal sheet modal interface that prompts the user to input a name and generate a new playlist[span_2](start_span)[span_2](end_span).
struct NewPlaylistSheet: View {
    
    // A mutable binding reference to the global playlist inventory array[span_3](start_span)[span_3](end_span).
    @Binding var playlists: [Playlist]
    
    // The structural dismissal action used to close the sheet from the environment pipeline[span_4](start_span)[span_4](end_span).
    @Environment(\.dismiss) private var dismiss
    
    // The state-tracked string value bound to the input text field[span_5](start_span)[span_5](end_span).
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
    
    // Constructs a empty user playlist instance, commits it to the global array, updates storage registers, and closes the modal view[span_6](start_span)[span_6](end_span).
    private func createPlaylist() {
        let newPlaylist = Playlist(name: playlistName, songs: [])
        playlists.append(newPlaylist)
        PlaylistStore.shared.save(playlists)
        dismiss()
    }
}
