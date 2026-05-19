import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    var playlists: [Playlist]
    @Binding var userPlaylists: [Playlist]
    @Binding var selectedPlaylistID: UUID?
    @Binding var showNewPlaylistSheet: Bool
    @Binding var libraryActive: Bool
    @Binding var showITunesStore: Bool
    @EnvironmentObject var deviceMonitor: iPodDeviceMonitor
    @Binding var isDeviceSelected: Bool

    @State private var showComingSoon = false
    @State private var comingSoonSection = ""
    @State private var dropHoverPlaylistID: UUID? = nil

    private var allPlaylists: [Playlist] {
        playlists.filter { $0.isSystem } + userPlaylists
    }

    var body: some View {
        List {
            if let device = deviceMonitor.connectedDevice {
                Section("sidebar.devices") {
                    SidebarDeviceEntry(
                        device: device,
                        isSelected: isDeviceSelected,
                        onSelect: {
                            isDeviceSelected = true
                            selectedPlaylistID = nil
                            libraryActive = false
                            showITunesStore = false
                        }
                    )
                }
            }
            
            Section("sidebar.library") {
                Button(action: {
                    selectedPlaylistID = nil
                    libraryActive = true
                    showITunesStore = false
                }) {
                    Label("sidebar.music", systemImage: "music.note")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: libraryActive && selectedPlaylistID == nil))

                Button(action: { comingSoonSection = "Movies"; showComingSoon = true }) {
                    Label("sidebar.movies", systemImage: "film")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: false))

                Button(action: { comingSoonSection = "TV Shows"; showComingSoon = true }) {
                    Label("sidebar.tvShows", systemImage: "tv")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: false))

                Button(action: { comingSoonSection = "Podcasts"; showComingSoon = true }) {
                    Label("sidebar.podcasts", systemImage: "mic")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: false))

                Button(action: { comingSoonSection = "Radio"; showComingSoon = true }) {
                    Label("sidebar.radio", systemImage: "radio")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: false))

                Button(action: { comingSoonSection = "Purchased"; showComingSoon = true }) {
                    Label("sidebar.purchased", systemImage: "purchased")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: false))
            }
            
            Section("sidebar.store") {
                Button(action: {
                    selectedPlaylistID = nil
                    libraryActive = false
                    showITunesStore = true
                }) {
                    Label("sidebar.iTunesStore", systemImage: "bag")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: showITunesStore))
            }
            
            Section("sidebar.playlists") {
                Button(action: { comingSoonSection = "Genius"; showComingSoon = true }) {
                    Label("sidebar.genius", systemImage: "atom")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ITunesSidebarButtonStyle(selected: false))

                ForEach(allPlaylists) { playlist in
                    Button(action: {
                        selectedPlaylistID = playlist.id
                        libraryActive = false
                        showITunesStore = false
                    }) {
                        Label(playlist.name, systemImage: playlist.isSystem ? "gearshape" : "music.note.list")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ITunesSidebarButtonStyle(selected: selectedPlaylistID == playlist.id && !libraryActive))
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor.opacity(dropHoverPlaylistID == playlist.id ? 0.8 : 0), lineWidth: 2)
                    )
                    .onDrop(of: [UTType.json], isTargeted: Binding(get: { dropHoverPlaylistID == playlist.id }, set: { isTargeted in
                        dropHoverPlaylistID = isTargeted ? playlist.id : nil
                    })) { providers in
                        return handleDrop(providers: providers, for: playlist)
                    }
                }
                
                Button(action: {
                    showNewPlaylistSheet = true
                }) {
                    Label("sidebar.newPlaylist", systemImage: "plus")
                }
            }
        }
        .listStyle(SidebarListStyle())
        .background(Color.itunesSidebar)
        .foregroundColor(.primary)
        .alert("alert.comingSoon.title", isPresented: $showComingSoon) {
            Button("alert.ok", role: .cancel) { }
        } message: {
            Text(String(format: NSLocalizedString("alert.comingSoon.message", comment: "comingSoon"), comingSoonSection))
        }
    }
    
    // Stupid type-checking thing why aaaaaaaaaaaaaaaaaaaaaaaaaaa
    
    private func handleDrop(providers: [NSItemProvider], for playlist: Playlist) -> Bool {
        var handled = false
        let group = DispatchGroup()

        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.json.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = (item as? Data) ?? (item as? URL).flatMap({ try? Data(contentsOf: $0) }) else { return }

                if let song = try? JSONDecoder().decode(Song.self, from: data) {
                    Task { @MainActor in
                        if let idx = userPlaylists.firstIndex(where: { $0.id == playlist.id }) {
                            if !userPlaylists[idx].songs.contains(where: { $0.id == song.id }) {
                                withAnimation { userPlaylists[idx].songs.append(song) }
                            }
                        }
                    }
                    handled = true
                } else if let list = try? JSONDecoder().decode([Song].self, from: data) {
                    Task { @MainActor in
                        if let idx = userPlaylists.firstIndex(where: { $0.id == playlist.id }) {
                            let existing = Set(userPlaylists[idx].songs.map { $0.id })
                            let toAdd = list.filter { !existing.contains($0.id) }
                            if !toAdd.isEmpty {
                                withAnimation { userPlaylists[idx].songs.append(contentsOf: toAdd) }
                            }
                        }
                    }
                    handled = true
                }
            }
        }

        group.notify(queue: .main) {
            // Clear hover state and select playlist so user sees updates immediately
            withAnimation { dropHoverPlaylistID = nil }
            if handled {
                selectedPlaylistID = playlist.id
                libraryActive = false
                showITunesStore = false
            }
        }

        return handled
    }
}

struct ITunesSidebarButtonStyle: ButtonStyle {
    var selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var selectionColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.17, green: 0.28, blue: 0.52),
                Color(red: 0.10, green: 0.20, blue: 0.42)
            ]
        } else {
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
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08))
        } else {
            Color.clear
        }
    }
}
