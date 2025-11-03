import SwiftUI
import AVKit
import Combine
import MediaPlayer

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
    @State private var currentPlaybackSongs: [Song] = []
    @State private var isShuffleEnabled = false
    @State private var isRepeatEnabled = false
    @State private var isRepeatOne = false
    @State private var isStopped = false
    @State private var systemPlaylists: [Playlist] = []
    @State private var selectedPlaylistID: UUID?
    @State private var libraryActive: Bool = true

    @State private var showNewPlaylistSheet = false
    @StateObject private var playlistManager = PlaylistManager()
    
    // New states for playlist selection
    @State private var showPlaylistSelectionSheet = false
    @State private var songToAddToPlaylist: Song?
    
    // MiniPlayer states
    @State private var isMiniPlayerActive = false
    @State private var miniPlayerWindow: NSWindow?
    @State private var isPlayingFlag: Bool = false
    
    // Up Next states
    @State private var showUpNext = false
    @State private var upcomingSongs: [Song] = []
    @State private var shuffleQueue: [Song] = []

    private var playlists: [Playlist] {
        playlistManager.userPlaylists + systemPlaylists
    }

    private var displayedSongs: [Song] {
        if let playlistID = selectedPlaylistID,
           let playlist = playlists.first(where: { $0.id == playlistID }) {
            // Preserve the playlist's visible order while removing duplicates
            var seen = Set<UUID>()
            var result: [Song] = []
            for s in playlist.songs {
                if !seen.contains(s.id) {
                    seen.insert(s.id)
                    result.append(s)
                }
            }
            return result
        }
        // Preserve the library's visible order while removing duplicates
        var seen = Set<UUID>()
        var result: [Song] = []
        for s in songs {
            if !seen.contains(s.id) {
                seen.insert(s.id)
                result.append(s)
            }
        }
        return result
    }

    // Build the playback context based on current selection, sorted alphabetically
    private func playbackContext(for seedSong: Song?) -> [Song] {
        // Determine base list according to current UI context
        let base: [Song]
        if let _ = selectedPlaylistID {
            base = displayedSongs
        } else if isAlbumView, let seed = seedSong {
            base = songs.filter { $0.album == seed.album }
        } else {
            base = displayedSongs
        }
        // Deduplicate while preserving order
        var seen = Set<UUID>()
        var deduped: [Song] = []
        for s in base {
            if !seen.contains(s.id) {
                seen.insert(s.id)
                deduped.append(s)
            }
        }
        // Sort alphabetically by title, then artist
        return deduped.sorted { a, b in
            let t = a.title.localizedCaseInsensitiveCompare(b.title)
            if t == .orderedSame {
                return a.artist.localizedCaseInsensitiveCompare(b.artist) == .orderedAscending
            }
            return t == .orderedAscending
        }
    }

    private func alphabeticalIndex(of song: Song, in list: [Song]) -> Int? {
        return list.firstIndex { $0.id == song.id }
    }
    
    private func rebuildShuffleQueue(startingFrom current: Song) {
        let context = playbackContext(for: current)
        let pool = context.filter { $0.id != current.id }
        shuffleQueue = pool.shuffled()
    }

    var body: some View {
        Group {
            if isMiniPlayerActive {
                // Empty view when mini player is active
                EmptyView()
            } else {
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
                                    updateNowPlayingInfo()
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
                        isRepeatOne: $isRepeatOne,
                        isStopped: $isStopped,
                        onMiniPlayerToggle: toggleMiniPlayer
                    )

                    Divider()

                    HStack(spacing: 0) {
                        NavigationView {
                            SidebarView(
                                playlists: playlists,
                                userPlaylists: $playlistManager.userPlaylists,
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
                        
                        if showUpNext {
                            Divider()
                            UpNextView(
                                currentSong: selectedSong,
                                upcomingSongs: upcomingSongs,
                                isPlaying: (player?.rate ?? 0) > 0
                            )
                            .frame(width: 300)
                        }
                    }
                    
                    // Bottom bar
                    Divider()
                    HStack {
                        Spacer()
                        Button(action: {
                            withAnimation {
                                showUpNext.toggle()
                                if showUpNext {
                                    updateUpcomingSongs()
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "list.bullet")
                                Text("Up Next")
                            }
                        }
                        .padding(.horizontal)
                        .foregroundColor(.primary)
                        .buttonStyle(PlainButtonStyle())
                    }
                    .frame(height: 40)
                    .background(Color(NSColor.controlBackgroundColor))
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
                    setupRemoteCommands()
                }
                .sheet(isPresented: $showNewPlaylistSheet) {
                    NewPlaylistSheet(playlists: $playlistManager.userPlaylists)
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
                    updateNowPlayingInfo()
                    updateUpcomingSongs()
                }
                .onChange(of: volume) { _ in
                    player?.volume = Float(volume)
                    updateNowPlayingInfo()
                }
                .onChange(of: isShuffleEnabled) { enabled in
                    if enabled {
                        if let song = selectedSong {
                            rebuildShuffleQueue(startingFrom: song)
                        }
                    } else {
                        shuffleQueue.removeAll()
                    }
                    updateUpcomingSongs()
                }
            }
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
        currentPlaybackSongs = playbackContext(for: song)
        if isShuffleEnabled {
            rebuildShuffleQueue(startingFrom: song)
        }
        
        setupNewPlayback(for: song)
        updateUpcomingSongs()
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
        isPlayingFlag = true
        
        player = newPlayer
        playerItem = item
        selectedSong = song
        playbackDuration = item.asset.duration.seconds
        playbackPosition = 0.0

        setupTimeObserver(for: newPlayer)
        setupPlaybackCompletionHandler(for: item)
        updateNowPlayingInfo()
    }
    
    private func stopCurrentPlayback() {
        player?.pause()
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        playerItem = nil
        player = nil
        isPlayingFlag = false
    }
    
    private func setupTimeObserver(for player: AVPlayer) {
        let interval = CMTime(seconds: 1.0, preferredTimescale: 1)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            if !self.isSeeking {
                self.playbackPosition = seconds / max(self.playbackDuration, 0.1)
                self.updateNowPlayingPlaybackInfo()
            }
        }
    }
    
    private func setupPlaybackCompletionHandler(for item: AVPlayerItem) {
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            if self.isRepeatOne {
                // Loop the same item by seeking to start and resuming playback
                self.player?.seek(to: .zero)
                self.player?.play()
                self.isPlayingFlag = true
                self.playbackPosition = 0.0
                self.updateNowPlayingInfo()
            } else {
                self.playNext()
            }
        }
    }
    
    private func playNext() {
        guard let current = selectedSong else { return }

        if isShuffleEnabled {
            // Use the persistent shuffle queue
            if shuffleQueue.isEmpty {
                if isRepeatEnabled || isRepeatOne {
                    rebuildShuffleQueue(startingFrom: current)
                }
            }
            if let next = shuffleQueue.first {
                shuffleQueue.removeFirst()
                playSong(next)
                return
            } else {
                return
            }
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
        currentPlaybackSongs = playbackContext(for: current)
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
        currentPlaybackSongs = playbackContext(for: current)
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
            updateNowPlayingPlaybackInfo()
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
    
    // System audio controls implementation
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Play command
        commandCenter.playCommand.addTarget { _ in
            guard let player = self.player else { return .commandFailed }
            if player.rate == 0 {
                player.play()
                self.isPlayingFlag = true
                self.updateNowPlayingInfo()
                return .success
            }
            return .commandFailed
        }
        
        // Pause command
        commandCenter.pauseCommand.addTarget { _ in
            guard let player = self.player else { return .commandFailed }
            if player.rate != 0 {
                player.pause()
                self.isPlayingFlag = false
                self.updateNowPlayingInfo()
                return .success
            }
            return .commandFailed
        }
        
        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            guard let player = self.player else { return .commandFailed }
            if player.rate == 0 {
                player.play()
                self.isPlayingFlag = true
            } else {
                player.pause()
                self.isPlayingFlag = false
            }
            self.updateNowPlayingInfo()
            return .success
        }
        
        // Next track command
        commandCenter.nextTrackCommand.addTarget { _ in
            self.playNext()
            return .success
        }
        
        // Previous track command
        commandCenter.previousTrackCommand.addTarget { _ in
            self.playPrevious()
            return .success
        }
        
        // Change playback position command
        commandCenter.changePlaybackPositionCommand.addTarget { event in
            guard let player = self.player else { return .commandFailed }
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            
            let time = CMTime(seconds: event.positionTime, preferredTimescale: 600)
            player.seek(to: time)
            self.updateNowPlayingPlaybackInfo()
            return .success
        }
    }
    
    private func updateNowPlayingInfo() {
        guard let song = selectedSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        var nowPlayingInfo = [String: Any]()
        
        // Basic track information
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = song.album
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = playbackDuration
        
        // Artwork if available
        if let artworkData = song.artworkData,
           let artworkImage = NSImage(data: artworkData) {
            let artwork = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        
        // Playback position
        if let player = player {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
        }
        
        // Playback rate
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player?.rate ?? 0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func updateNowPlayingPlaybackInfo() {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        
        // Update playback position
        if let player = player {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
        }
        
        // Update playback rate
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player?.rate ?? 0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    // Up Next functionality
    private func updateUpcomingSongs() {
        guard let current = selectedSong else {
            upcomingSongs = []
            return
        }

        currentPlaybackSongs = playbackContext(for: current)

        var upcoming: [Song] = []
        
        if isShuffleEnabled {
            // Show the next items from the persistent shuffle queue
            upcoming = Array(shuffleQueue.prefix(15))
        } else {
            // Get next sequential songs
            if let currentIndex = currentPlaybackSongs.firstIndex(where: { $0.id == current.id }) {
                let startIndex = currentIndex + 1
                let endIndex = min(startIndex + 15, currentPlaybackSongs.count) // Show up to 5 songs
                
                if startIndex < endIndex {
                    upcoming = Array(currentPlaybackSongs[startIndex..<endIndex])
                }
                
                // If we're near the end and repeat is enabled, add songs from the beginning
                if (isRepeatEnabled || isRepeatOne) && upcoming.count < 15 {
                    let additionalNeeded = 15 - upcoming.count
                    let additionalSongs = currentPlaybackSongs.prefix(additionalNeeded)
                    upcoming.append(contentsOf: additionalSongs)
                }
            }
        }
        
        upcomingSongs = upcoming
    }
    
    // MiniPlayer functionality
    private func toggleMiniPlayer() {
        if isMiniPlayerActive {
            closeMiniPlayer()
        } else {
            openMiniPlayer()
        }
    }
    
    private func openMiniPlayer() {
        guard let selectedSong = selectedSong else { return }
        
        isMiniPlayerActive = true
        isPlayingFlag = (player?.rate != 0)
        
        // Hide main window
        if let mainWindow = NSApp.mainWindow {
            mainWindow.orderOut(nil)
        }
        
        // Create and show mini player window
        let miniPlayerView = MiniPlayerView(
            player: player,
            selectedSong: $selectedSong,
            isPlaying: $isPlayingFlag,
            volume: $volume,
            playbackPosition: $playbackPosition,
            playbackDuration: $playbackDuration,
            onPlayPause: { 
                if self.player?.rate != 0 {
                    self.player?.pause()
                    self.isPlayingFlag = false
                    self.updateNowPlayingInfo()
                } else {
                    self.player?.play()
                    self.isPlayingFlag = true
                    self.updateNowPlayingInfo()
                }
            },
            onPrevious: playPrevious,
            onNext: playNext,
            onSeek: handleSeek,
            onClose: closeMiniPlayer
        )
        
        let hostingController = NSHostingController(rootView: miniPlayerView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 100),
            styleMask: [.titled, .closable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.contentViewController = hostingController
        window.title = "MiniPlayer"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        // Make the window stay on top
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        miniPlayerWindow = window
        
        // Set up notification to detect when mini player is closed
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            self.handleMiniPlayerClose()
        }
    }
    
    private func handleMiniPlayerClose() {
        if isMiniPlayerActive {
            closeMiniPlayer()
        }
    }
    
    private func closeMiniPlayer() {
        isMiniPlayerActive = false
        
        // Close mini player window
        miniPlayerWindow?.close()
        miniPlayerWindow = nil
        
        // Show main window
        if let mainWindow = NSApp.mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            // If main window reference is lost, we need to recreate the app window
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        
        // Remove observer
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
    }
}

struct UpNextView: View {
    let currentSong: Song?
    let upcomingSongs: [Song]
    let isPlaying: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Up Next")
                .font(.headline)
                .padding(.horizontal)
            
            if let current = currentSong {
                // Current playing song
                HStack(spacing: 12) {
                    if let artworkData = current.artworkData,
                       let image = NSImage(data: artworkData) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 50, height: 50)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(current.artist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.blue)
                }
                .padding(.horizontal)
                
                Divider()
            }
            
            if !upcomingSongs.isEmpty {
                Text("Next Up")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                
                // List of upcoming songs
                List(upcomingSongs.indices, id: \.self) { index in
                    let song = upcomingSongs[index]
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 20)
                        
                        if let artworkData = song.artworkData,
                           let image = NSImage(data: artworkData) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        } else {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 40, height: 40)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(song.artist)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(PlainListStyle())
            } else if isPlaying {
                Text("No upcoming songs")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No song playing")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

