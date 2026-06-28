import SwiftUI

// A sheet/dialog that lets the user pick an existing playlist to add a given
// song to. Shows a checkmark next to playlists that already contain the song.
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

            Text(String(format: NSLocalizedString("playlistSelection.message", comment: "message"), song.title))
                .font(.subheadline)
                .foregroundColor(.secondary)

            if playlistManager.userPlaylists.isEmpty {
                // No playlists exist yet — show an empty-state message.
                Text(String(format: NSLocalizedString("playlistSelection.message", comment: "message"), song.title))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                // List every user playlist; tapping a row adds the song to
                // that playlist and dismisses the sheet.
                List(playlistManager.userPlaylists) { playlist in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(playlist.name)
                                .font(.body)

                            Text(String(format: NSLocalizedString("playlistSelection.songCount", comment: "songCount"), playlist.songs.count))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        // Show a checkmark if the song is already in this playlist.
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
