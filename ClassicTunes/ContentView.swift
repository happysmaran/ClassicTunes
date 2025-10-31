import SwiftUI
import AVKit

struct ContentView: View {
    @AppStorage("musicFolderBookmark") private var musicFolderBookmarkData: Data = Data()
    @State private var musicFolderAccess: URL?
    @State private var isAlbumView = false
    @State private var showFileImporter = false
    @State private var songs: [Song] = []
    @State private var selectedSong: Song?
    @State private var player: AVPlayer?
    @State private var playerItem: AVPlayerItem?
    @AppStorage("playerVolume") private var volume: Double = 0.5
    @State private var playbackPosition: Double = 0.0
    @State private var playbackDuration: Double = 1.0
    @State private var timeObserverToken: Any?
    @State private var isSeeking = false
    @State private var currentAlbumSongs: [Song] = []
    @State private var isShuffleEnabled = false
    @State private var isRepeatEnabled = false
    @State private var isStopped = false
    @State private var userPlaylists: [Playlist] = []
    @State private var systemPlaylists: [Playlist] = []
    @State private var selectedPlaylistID: UUID?
    @State private var libraryActive: Bool = true

    @State private var showNewPlaylistSheet = false

    private var playlists: [Playlist] {
        userPlaylists + systemPlaylists
    }

    private var displayedSongs: [Song] {
        if let playlistID = selectedPlaylistID,
           let playlist = playlists.first(where: { $0.id == playlistID }) {
            let unique = Array(Dictionary(uniqueKeysWithValues: playlist.songs.map { ($0.id, $0) }).values)
            return unique
        }
        return Array(Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) }).values)
    }

    var body: some View {
        VStack(spacing: 0) {
            TopToolbarView(
                isAlbumView: $isAlbumView,
                showFileImporter: $showFileImporter,
                selectedSong: $selectedSong,
                isPlaying: Binding(
                    get: { player?.rate != 0 },
                    set: { shouldPlay in
                        if shouldPlay {
                            player?.play()
                        } else {
                            player?.pause()
                        }
                    }
                ),
                playPrevious: playPrevious,
                playNext: playNext,
                volume: $volume,
                playbackPosition: $playbackPosition,
                playbackDuration: $playbackDuration,
                onSeek: handleSeek,
                isSeeking: $isSeeking,
                isShuffleEnabled: $isShuffleEnabled,
                isRepeatEnabled: $isRepeatEnabled,
                isStopped: $isStopped
            )

            Divider()

            NavigationView {
                SidebarView(
                    playlists: playlists,
                    userPlaylists: $userPlaylists,
                    selectedPlaylistID: $selectedPlaylistID,
                    showNewPlaylistSheet: $showNewPlaylistSheet,
                    libraryActive: $libraryActive
                )
                
                SongListView(
                    isAlbumView: isAlbumView,
                    songs: songs,
                    onSongSelect: playSong,
                    selectedSong: $selectedSong,
                    onAlbumSelect: { album in
                        let albumSongs = songs.filter { $0.album == album }
                        if let firstSong = albumSongs.first {
                            currentAlbumSongs = albumSongs
                            playSong(firstSong)
                        }
                    },
                    playlistSongs: selectedPlaylistID != nil ? displayedSongs : nil
                )
            }
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.directory], allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            print("Running loadSongsOnce at launch")
            loadSongsOnce()
            userPlaylists = loadUserPlaylists().filter { !$0.isSystem }
            generateSystemPlaylists()
        }
        .sheet(isPresented: $showNewPlaylistSheet) {
            NewPlaylistSheet(playlists: $userPlaylists)
        }
        .onChange(of: selectedSong) { newSong in
            guard let song = newSong else { return }
            incrementPlayCount(for: song)
            generateSystemPlaylists()
            refreshSongPlayCounts()
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let folderURL = urls.first {
                if folderURL.startAccessingSecurityScopedResource() {
                    do {
                        musicFolderAccess = folderURL
                        let bookmark = try folderURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                        musicFolderBookmarkData = bookmark
                        print("Saved security-scoped bookmark.")
                        songs = loadSongs(from: folderURL)
                        generateSystemPlaylists()
                    } catch {
                        print("Failed to create bookmark: \(error)")
                    }
                } else {
                    print("Failed to access security scope.")
                }
            }
        case .failure(let error):
            print("Folder selection failed: \(error.localizedDescription)")
        }
    }

    private func loadSongsOnce() {
        guard !musicFolderBookmarkData.isEmpty else { return }

        do {
            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: musicFolderBookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)

            if resolvedURL.startAccessingSecurityScopedResource() {
                musicFolderAccess = resolvedURL
                songs = loadSongs(from: resolvedURL)
                print("Successfully loaded songs from bookmark.")
                generateSystemPlaylists()
            } else {
                print("Failed to access security scoped resource from bookmark.")
            }
        } catch {
            print("Error resolving bookmark: \(error)")
        }
    }

    private func playSong(_ song: Song) {
        guard musicFolderAccess != nil else {
            print("No folder access retained.")
            return
        }

        // Increment play counts and system playlists are handled by onChange(of: selectedSong)
        currentAlbumSongs = isAlbumView ? songs.filter { $0.album == song.album } : songs
        setupNewPlayback(for: song)
    }
    
    private func refreshSongPlayCounts() {
        for i in songs.indices {
            songs[i].playCount = getPlayCount(for: songs[i])
        }
    }

    private func setupNewPlayback(for song: Song) {
        stopCurrentPlayback()
        
        let item = AVPlayerItem(url: song.url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = Float(volume)
        newPlayer.play()
        
        player = newPlayer
        playerItem = item
        selectedSong = song
        playbackDuration = item.asset.duration.seconds
        playbackPosition = 0.0

        setupTimeObserver(for: newPlayer)
        setupPlaybackCompletionHandler(for: item)
    }
    
    private func stopCurrentPlayback() {
        player?.pause()
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        playerItem = nil
        player = nil
    }
    
    private func setupTimeObserver(for player: AVPlayer) {
        let interval = CMTime(seconds: 1.0, preferredTimescale: 1)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            let seconds = time.seconds
            if !self.isSeeking {
                self.playbackPosition = seconds / max(self.playbackDuration, 0.1)
            }
        }
    }
    
    private func setupPlaybackCompletionHandler(for item: AVPlayerItem) {
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [self] _ in
            self.playNext()
        }
    }
    
    private func playNext() {
        guard let current = selectedSong else { return }

        if isShuffleEnabled {
            playRandomSong(excluding: current)
            return
        }

        playNextSequentialSong(after: current)
    }
    
    private func playRandomSong(excluding current: Song) {
        let pool = currentAlbumSongs.filter { $0.id != current.id }
        if let randomSong = pool.randomElement() {
            playSong(randomSong)
        }
    }
    
    private func playNextSequentialSong(after current: Song) {
        guard let currentIndex = currentAlbumSongs.firstIndex(where: { $0.id == current.id }) else { return }

        let nextIndex = currentIndex + 1
        if nextIndex < currentAlbumSongs.count {
            playSong(currentAlbumSongs[nextIndex])
        } else if isRepeatEnabled {
            playSong(currentAlbumSongs.first!)
        }
    }

    private func playPrevious() {
        guard let current = selectedSong else { return }

        if isShuffleEnabled {
            playRandomSong(excluding: current)
            return
        }

        playPreviousSequentialSong(before: current)
    }
    
    private func playPreviousSequentialSong(before current: Song) {
        guard let currentIndex = currentAlbumSongs.firstIndex(where: { $0.id == current.id }) else { return }

        let previousIndex = currentIndex - 1
        if previousIndex >= 0 {
            playSong(currentAlbumSongs[previousIndex])
        } else if isRepeatEnabled {
            playSong(currentAlbumSongs.last!)
        }
    }
    
    private func handleSeek(_ value: Double) {
        if value == -1 {
            player?.volume = Float(volume)
        } else {
            let seconds = value * playbackDuration
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            player?.seek(to: time)
        }
    }

    private func generateSystemPlaylists() {
        let uniqueSongs = Array(Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) }).values)
        systemPlaylists = [
            generateRecentlyPlayedPlaylist(from: uniqueSongs),
            generateTopPlayedPlaylist(from: uniqueSongs)
        ]
    }

    private func generateTopPlayedPlaylist(from songs: [Song]) -> Playlist {
        let topPlayedSongs = songs.sorted(by: { $0.playCount > $1.playCount }).prefix(25)
        return Playlist(name: "Top 25 Most Played", songs: Array(topPlayedSongs), isSystem: true)
    }

    private func loadUserPlaylists() -> [Playlist] {
        loadPlaylistsFromUserDefaults()
    }

    private func saveUserPlaylists(_ playlists: [Playlist]) {
        savePlaylistsToUserDefaults(playlists)
    }
}

struct SidebarView: View {
    let playlists: [Playlist]
    @Binding var userPlaylists: [Playlist]
    @Binding var selectedPlaylistID: UUID?
    @Binding var showNewPlaylistSheet: Bool
    @Binding var libraryActive: Bool

    var body: some View {
        List {
            Section("LIBRARY") {
                Label("Music", systemImage: "music.note")
                    .onTapGesture {
                        selectedPlaylistID = nil
                        libraryActive = true
                    }
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
                                // Action to delete the playlist
                                if let index = userPlaylists.firstIndex(where: { $0.id == playlist.id }) {
                                    userPlaylists.remove(at: index)
                                    savePlaylistsToUserDefaults(userPlaylists)
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
                        libraryActive = false
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
