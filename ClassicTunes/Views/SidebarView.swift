import SwiftUI

struct SidebarView: View {
    var playlists: [Playlist]
    @Binding var userPlaylists: [Playlist]
    @Binding var selectedPlaylistID: UUID?
    @Binding var showNewPlaylistSheet: Bool
    @Binding var libraryActive: Bool
    @Binding var showITunesStore: Bool

    @State private var showComingSoon = false
    @State private var comingSoonSection = ""

    private var allPlaylists: [Playlist] {
        userPlaylists + playlists.filter { $0.isSystem }
    }

    var body: some View {
        List {
            Section("LIBRARY") {
                Button(action: {
                    selectedPlaylistID = nil
                    libraryActive = true
                    showITunesStore = false
                }) {
                    Label("Music", systemImage: "music.note")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: libraryActive && selectedPlaylistID == nil))

                Button(action: { comingSoonSection = "Movies"; showComingSoon = true }) {
                    Label("Movies", systemImage: "film")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: false))

                Button(action: { comingSoonSection = "TV Shows"; showComingSoon = true }) {
                    Label("TV Shows", systemImage: "tv")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: false))

                Button(action: { comingSoonSection = "Podcasts"; showComingSoon = true }) {
                    Label("Podcasts", systemImage: "mic")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: false))

                Button(action: { comingSoonSection = "Radio"; showComingSoon = true }) {
                    Label("Radio", systemImage: "radio")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: false))
            }
            
            Section("STORE") {
                Button(action: {
                    selectedPlaylistID = nil
                    libraryActive = false
                    showITunesStore = true
                }) {
                    Label("iTunes Store", systemImage: "bag")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: showITunesStore))
            }
            
            Section("PLAYLISTS") {
                ForEach(allPlaylists) { playlist in
                    Button(action: {
                        selectedPlaylistID = playlist.id
                        libraryActive = false
                        showITunesStore = false
                    }) {
                        HStack {
                            Text(playlist.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(ITunesSidebarButtonStyle(selected: selectedPlaylistID == playlist.id && !libraryActive))
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
        .alert("Coming Soon", isPresented: $showComingSoon) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("\(comingSoonSection) is coming soon.")
        }
    }
}

struct ITunesSidebarButtonStyle: ButtonStyle {
    var selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var selectionColors: [Color] {
        if colorScheme == .dark {
            // Dark mode: deeper blues with subtle contrast
            return [
                Color(red: 0.17, green: 0.28, blue: 0.52),
                Color(red: 0.10, green: 0.20, blue: 0.42)
            ]
        } else {
            // Light mode: classic iTunes blue
            return [
                Color(red: 0.65, green: 0.80, blue: 1.0),
                Color(red: 0.45, green: 0.65, blue: 1.0)
            ]
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(isPressed: configuration.isPressed))
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func background(isPressed: Bool) -> some View {
        if selected {
            // Classic selection look
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: selectionColors),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 0.5, x: 0, y: 1)
        } else if isPressed {
            // Pressed feedback
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08))
        } else {
            Color.clear
        }
    }
}

