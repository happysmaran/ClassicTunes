import SwiftUI

// A modal sheet modal interface that prompts the user to input a name and generate a new playlist[span_2](start_span)[span_2](end_span).
struct NewPlaylistSheet: View {
    
    // A mutable binding reference to the global playlist inventory array[span_3](start_span)[span_3](end_span).
    @Binding var playlists: [Playlist]
    
    // Called with the finished playlist when the user creates a smart playlist instead.
    var onSaveSmart: (Playlist) -> Void
    
    // The structural dismissal action used to close the sheet from the environment pipeline[span_4](start_span)[span_4](end_span).
    @Environment(\.dismiss) private var dismiss
    
    // The state-tracked string value bound to the input text field[span_5](start_span)[span_5](end_span).
    @State private var playlistName = ""
    
    // Whether the user chose to build a smart playlist (rule-based) instead of a regular one.
    @State private var isSmart = false
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $isSmart) {
                Text("newPlaylist.type.regular").tag(false)
                Text("newPlaylist.type.smart").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.top, .horizontal])
            .frame(width: isSmart ? 560 : 300)
            
            if isSmart {
                SmartPlaylistEditorSheet(onSave: onSaveSmart)
            } else {
                regularPlaylistForm
            }
        }
    }
    
    private var regularPlaylistForm: some View {
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
