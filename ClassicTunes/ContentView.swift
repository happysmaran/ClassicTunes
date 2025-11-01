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
    @State private var currentPlaybackSongs: [Song] = []  // Changed from currentAlbumSongs
    @State private var isShuffleEnabled = false
    @State private var isRepeatEnabled = false
    @State private var isRepeatOne = false  // This is managed internally by TopToolbarView's RepeatButton
    @State private var isStopped = false
    @State private var systemPlaylists: [Playlist] = []
    @State private var selectedPlaylistID: UUID?
    @State private var libraryActive: Bool = true

    @State private var showNewPlaylistSheet = false
    @StateObject private var playlistManager = PlaylistManager()
    
    // New states for playlist selection
    @State private var showPlaylistSelectionSheet = false
    @State private var songToAddToPlaylist: Song?

    private var playlists: [Playlist] {
        playlistManager.userPlaylists + systemPlaylists
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
                isRepeatEnabled: $isRepeatEnabled,  // This now represents repeat all
                isRepeatOne: $isRepeatOne,  // Added missing binding
                isStopped: $isStopped
            )

            Divider()

            NavigationView {
                SidebarView(
                    playlists: playlists,
                    userPlaylists: $playlistManager.userPlaylists, // Fixed: Correct binding syntax
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
                            currentPlaybackSongs = albumSongs
                            playSong(firstSong)
                        }
                    },
                    playlistSongs: selectedPlaylistID != nil ? displayedSongs : nil,
                    onAddToPlaylist: { song in
                        songToAddToPlaylist = song
                        showPlaylistSelectionSheet = true
                    }
                )
                .environmentObject(playlistManager)
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
            generateSystemPlaylists()
        }
        .sheet(isPresented: $showNewPlaylistSheet) {
            NewPlaylistSheet(playlists: $playlistManager.userPlaylists) // Fixed: Also corrected here
        }
        .sheet(isPresented: $showPlaylistSelectionSheet) {
            if let song = songToAddToPlaylist {
                PlaylistSelectionView(song: song) { playlist in
                    playlistManager.addSong(song, to: playlist)
                    showPlaylistSelectionSheet = false
                }
                .environmentObject(playlistManager)
            }
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

        // Set the correct playback context based on what we're playing from
        if let playlistID = selectedPlaylistID,
           let playlist = playlists.first(where: { $0.id == playlistID }) {
            // Playing from a playlist
            currentPlaybackSongs = playlist.songs
        } else if isAlbumView {
            // Playing from album view
            currentPlaybackSongs = songs.filter { $0.album == song.album }
        } else {
            // Playing from main library
            currentPlaybackSongs = songs
        }
        
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
            if isRepeatOne {
                // Repeat the same song
                if let currentSong = selectedSong {
                    playSong(currentSong)
                }
            } else {
                self.playNext()
            }
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
        let pool = currentPlaybackSongs.filter { $0.id != current.id }
        if let randomSong = pool.randomElement() {
            playSong(randomSong)
        }
    }
    
    private func playNextSequentialSong(after current: Song) {
        guard let currentIndex = currentPlaybackSongs.firstIndex(where: { $0.id == current.id }) else { return }

        let nextIndex = currentIndex + 1
        if nextIndex < currentPlaybackSongs.count {
            playSong(currentPlaybackSongs[nextIndex])
        } else if isRepeatEnabled || isRepeatOne {
            // When repeat is enabled, go back to the first song
            playSong(currentPlaybackSongs.first!)
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
        guard let currentIndex = currentPlaybackSongs.firstIndex(where: { $0.id == current.id }) else { return }

        let previousIndex = currentIndex - 1
        if previousIndex >= 0 {
            playSong(currentPlaybackSongs[previousIndex])
        } else if isRepeatEnabled || isRepeatOne {
            // When repeat is enabled, go to the last song
            playSong(currentPlaybackSongs.last!)
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
    
    private func generateRecentlyPlayedPlaylist(from songs: [Song]) -> Playlist {
        let history = getPlayHistory()
        var seen = Set<String>()
        var recentSongs: [Song] = []
        for songID in history {
            if seen.contains(songID) { continue }
            if let song = songs.first(where: { $0.id.uuidString == songID }) {
                recentSongs.append(song)
                seen.insert(songID)
                if recentSongs.count == 25 { break }
            }
        }
        return Playlist(name: "Recently Played", songs: recentSongs, isSystem: true)
    }
    
    private func incrementPlayCount(for song: Song) {
        var playCounts = UserDefaults.standard.dictionary(forKey: "playCounts") as? [String: Int] ?? [:]
        let songID = song.id.uuidString
        playCounts[songID, default: 0] += 1
        UserDefaults.standard.set(playCounts, forKey: "playCounts")

        // Track play history
        var history = UserDefaults.standard.stringArray(forKey: "playHistory") ?? []
        history.insert(songID, at: 0)
        if history.count > 1000 { history = Array(history.prefix(1000)) }
        UserDefaults.standard.set(history, forKey: "playHistory")
    }
    
    private func getPlayCount(for song: Song) -> Int {
        let playCounts = UserDefaults.standard.dictionary(forKey: "playCounts") as? [String: Int] ?? [:]
        return playCounts[song.id.uuidString] ?? 0
    }
    
    private func getPlayHistory() -> [String] {
        UserDefaults.standard.stringArray(forKey: "playHistory") ?? []
    }
}
