import SwiftUI

struct NewPlaylistSheet: View {
    @Binding var playlists: [Playlist]
    @Environment(\.dismiss) var dismiss
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("New Playlist")) {
                    TextField("Playlist Name", text: $newPlaylistName)
                }

                Section {
                    Button("Create Playlist") {
                        let trimmedName = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedName.isEmpty else { return }

                        let playlist = Playlist(name: trimmedName, songs: [])
                        playlists.append(playlist)
                        savePlaylistsToUserDefaults(playlists)
                        dismiss()
                    }
                }
            }
            .padding()
            .navigationTitle("Create Playlist")
        }
    }
}

struct AnimatedLabel: View {
    let texts: [String]
    @State private var currentIndex = 0

    var body: some View {
        Text(texts[currentIndex])
            .transition(.opacity)
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
                    withAnimation {
                        currentIndex = (currentIndex + 1) % texts.count
                    }
                }
            }
    }
}