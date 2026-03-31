import SwiftUI
import AVKit
import Combine
import MediaPlayer

// the playlist code is a mess

class PersistentPlayer {
    static let shared = PersistentPlayer()
    var player: AVPlayer?
    var selectedSong: Song?
    private init() {}
}

class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Switch to accessory mode when the last window is closed
        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
        
        // Do not terminate the app
        return false
    }
}

struct ContentView: View {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    
    @AppStorage("musicFolderBookmark") private var musicFolderBookmarkData: Data = Data()
    @State private var musicFolderAccess: URL?
    @State private var isAlbumView = false
    @State private var isCoverFlowActive = false
    @State private var showFileImporter = false
    @State private var songs: [Song] = []
    @State private var selectedSong: Song?
    @State private var player: AVPlayer?
    @State private var playerItem: AVPlayerItem?
    @AppStorage("playerVolume") private var volume: Double = 0.5
    @AppStorage("appAppearance") private var appAppearance: String = "system" // "system", "light", or "dark"
    @State private var playbackPosition: Double = 0.0
    @State private var playbackDuration: Double = 1.0
    @State private var timeObserverToken: Any?
    @State private var isSeeking = false
    @State private var currentPlaybackSongs: [Song] = []
    @AppStorage("isShuffleEnabled") private var isShuffleEnabled = false
    @AppStorage("isRepeatEnabled") private var isRepeatEnabled = false
    @AppStorage("isRepeatOne") private var isRepeatOne = false
    @State private var isStopped = false
    @State private var systemPlaylists: [Playlist] = []
    @State private var selectedPlaylistID: UUID?
    @State private var libraryActive: Bool = true
    @State private var searchText: String = ""
    @State private var showITunesStore: Bool = false

    @State private var showNewPlaylistSheet = false
    @StateObject private var playlistManager = PlaylistManager()
    
    // Persistence keys
    private let userPlaylistsKey = "userPlaylists.v1"

    // New states for playlist selection
    @State private var showPlaylistSelectionSheet = false
    @State private var songToAddToPlaylist: Song?

    // MiniPlayer states
    @AppStorage("isMiniPlayerActive") private var isMiniPlayerActive = false
    @State private var miniPlayerWindow: NSWindow?

    // Added observer tokens
    @State private var playbackEndObserver: NSObjectProtocol?
    @State private var miniPlayerCloseObserver: NSObjectProtocol?

    // Up Next states
    @State private var showUpNext = false
    @State private var upcomingSongs: [Song] = []
    @State private var shuffleQueue: [Song] = []
    @State private var playedShuffleSongs: [Song] = []
    @State private var isNavigatingBackward = false

    // Lyrics states
    @State private var showLyrics = false
    @State private var lyricsText: String = ""

    @State private var showM3UExporter = false
    @State private var showM3UImporter = false
    @State private var m3UExportURL: URL?

    private var playlists: [Playlist] {
        playlistManager.userPlaylists + systemPlaylists
    }

    // Store large playlist data on disk instead of UserDefaults
    private func playlistsFileURL() -> URL? {
        do {
            let fm = FileManager.default
            let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let bundleID = Bundle.main.bundleIdentifier ?? "ClassicTunes"
            let dir = appSupport.appendingPathComponent(bundleID, isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir.appendingPathComponent("userPlaylists.v1.json")
        } catch {
            print("Failed to get Application Support directory: \(error)")
            return nil
        }
    }

    // One-time migration from UserDefaults to file-based storage for legacy users
    private func migratePlaylistsFromUserDefaultsIfNeeded() {
        guard let fileURL = playlistsFileURL() else { return }
        let fm = FileManager.default
        // If file already exists, assume migrated
        if fm.fileExists(atPath: fileURL.path) { return }

        guard let data = UserDefaults.standard.data(forKey: userPlaylistsKey) else { return }
        do {
            // Validate by decoding before writing to disk
            let decoder = JSONDecoder()
            let loaded = try decoder.decode([Playlist].self, from: data)
            try data.write(to: fileURL, options: [.atomic])
            // Clear the large value from UserDefaults after successful migration
            UserDefaults.standard.removeObject(forKey: userPlaylistsKey)
            playlistManager.userPlaylists = loaded
            print("Migrated playlists from UserDefaults to \(fileURL.path)")
        } catch {
            print("Migration failed, will keep using in-memory data this run: \(error)")
        }
    }

    private func loadUserPlaylists() {
        // Migrate any legacy UserDefaults data if needed
        migratePlaylistsFromUserDefaultsIfNeeded()

        guard let fileURL = playlistsFileURL() else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let loaded = try decoder.decode([Playlist].self, from: data)
            playlistManager.userPlaylists = loaded
        } catch {
            // If file missing or decode fails, leave as-is
            if (error as NSError).domain != NSCocoaErrorDomain || (error as NSError).code != NSFileReadNoSuchFileError {
                print("Failed to load playlists from disk: \(error)")
            }
        }
    }

    private func saveUserPlaylists() {
        guard let fileURL = playlistsFileURL() else { return }
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(playlistManager.userPlaylists)
            try data.write(to: fileURL, options: [.atomic])
            // Ensure we do not keep oversized data in UserDefaults
            if UserDefaults.standard.object(forKey: userPlaylistsKey) != nil {
                UserDefaults.standard.removeObject(forKey: userPlaylistsKey)
            }
        } catch {
            print("Failed to save playlists to disk: \(error)")
        }
    }
    
    private func restorePlaybackState() {
        guard let persistentSong = PersistentPlayer.shared.selectedSong,
              let persistentPlayer = PersistentPlayer.shared.player else { return }

        selectedSong = persistentSong
        player = persistentPlayer

        if let currentItem = persistentPlayer.currentItem {
            playbackDuration = currentItem.asset.duration.seconds
            playbackPosition = persistentPlayer.currentTime().seconds / max(playbackDuration, 0.1)
        }

        setupTimeObserver(for: persistentPlayer)
        if let item = persistentPlayer.currentItem {
            setupPlaybackCompletionHandler(for: item)
        }

        currentPlaybackSongs = playbackContext(for: persistentSong)
        updateUpcomingSongs()
        updateNowPlayingInfo()

        // Rebuild shuffle queue if shuffle was on
        if isShuffleEnabled {
            rebuildShuffleQueue(startingFrom: persistentSong)
        }
    }

    private var displayedSongs: [Song] {
        // Build base list depending on selected playlist or full library
        let baseUnfiltered: [Song]
        if let playlistID = selectedPlaylistID,
           let playlist = playlists.first(where: { $0.id == playlistID }) {
            baseUnfiltered = playlist.songs
        } else {
            baseUnfiltered = songs
        }

        // Deduplicate while preserving the visible order
        var seen = Set<UUID>()
        var orderedUnique: [Song] = []
        for s in baseUnfiltered {
            if !seen.contains(s.id) {
                seen.insert(s.id)
                orderedUnique.append(s)
            }
        }

        // If there's no search text, return as-is
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return orderedUnique
        }

        // Case-insensitive filtering by title, artist, or album
        let q = trimmedQuery.lowercased()
        return orderedUnique.filter { song in
            song.title.lowercased().contains(q) ||
            song.artist.lowercased().contains(q) ||
            song.album.lowercased().contains(q)
        }
    }

    // Get unique albums for Cover Flow
    private var albumsForCoverFlow: [AlbumInfo] {
        let groupedSongs = Dictionary(grouping: displayedSongs) { $0.album }
        var albumInfos: [AlbumInfo] = []

        // Shared normalized key function
        func normalizedSortKey(_ key: String) -> String {
            key.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "the ", with: "")
                .replacingOccurrences(of: "a ", with: "")
                .replacingOccurrences(of: "an ", with: "")
        }

        // Sort albums by normalized name to ensure consistent ordering
        let sortedAlbums = groupedSongs.sorted { lhs, rhs in
            normalizedSortKey(lhs.key).localizedCaseInsensitiveCompare(normalizedSortKey(rhs.key)) == .orderedAscending
        }

        for (albumName, songs) in sortedAlbums {
            if let firstSong = songs.first {
                albumInfos.append(AlbumInfo(
                    name: albumName,
                    artist: firstSong.artist,
                    artworkData: firstSong.artworkData
                ))
            }
        }

        return albumInfos
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

        // Clear the played songs history when rebuilding the queue
        playedShuffleSongs.removeAll()

        // Add the current song to the played history
        playedShuffleSongs.append(current)
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
                        isCoverFlowActive: $isCoverFlowActive,
                        onMiniPlayerToggle: toggleMiniPlayer,
                        searchText: $searchText
                    )

                    Divider()

                    HStack(spacing: 0) {
                        HStack(spacing: 0) {
                            SidebarView(
                                playlists: playlists,
                                userPlaylists: $playlistManager.userPlaylists,
                                selectedPlaylistID: $selectedPlaylistID,
                                showNewPlaylistSheet: $showNewPlaylistSheet,
                                libraryActive: $libraryActive,
                                showITunesStore: $showITunesStore
                            )
                            .frame(width: 220)
                            .tint(.blue)
                            .background(ITunesSidebarBackground())
	
                            Group {
                                if showITunesStore {
                                    iTunesStoreView()
                                } else if isCoverFlowActive {
                                    CoverFlowView(
                                        albums: albumsForCoverFlow,
                                        selectedAlbum: .constant(selectedSong?.album ?? ""),
                                        isCoverFlowActive: $isCoverFlowActive,
                                        onAlbumSelect: { albumName in
                                            let albumSongs = displayedSongs.filter { $0.album == albumName }
                                            if let firstSong = albumSongs.first {
                                                currentPlaybackSongs = albumSongs
                                                playSong(firstSong)
                                            }
                                        },
                                        songs: displayedSongs,
                                        selectedSong: $selectedSong,
                                        currentPlaybackSongs: $currentPlaybackSongs,
                                        shuffleQueue: $shuffleQueue,
                                        isShuffleEnabled: $isShuffleEnabled,
                                        isRepeatOne: $isRepeatOne,
                                        isRepeatEnabled: $isRepeatEnabled
                                    )
                                } else {
                                    SongListView(
                                        isAlbumView: isAlbumView,
                                        songs: displayedSongs,
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
                                        }
                                    )
                                    .environmentObject(playlistManager)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }

                        if showUpNext {
                            Divider()
                            UpNextView(
                                currentSong: selectedSong,
                                upcomingSongs: upcomingSongs,
                                isPlaying: (player?.rate ?? 0) > 0,
                                onSongSelect: playSongFromUpNext  // Added this parameter
                            )
                            .frame(width: 300)
                        }

                        if showLyrics {
                            Divider()
                            LyricsView(
                                currentSong: selectedSong,
                                lyrics: lyricsText
                            )
                            .frame(width: 300)
                        }
                    }

                    // Bottom bar - added lyrics button
                    Divider()
                    HStack {
                        Spacer()
                        Button(action: {
                            withAnimation {
                                showLyrics.toggle()
                                if showLyrics, let song = selectedSong {
                                    loadLyrics(for: song)
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "text.alignleft")
                                Text("Lyrics")
                            }
                        }
                        .padding(.horizontal)
                        .foregroundColor(.primary)
                        .buttonStyle(PlainButtonStyle())

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

                        Button(action: {
                            withAnimation { showM3UImporter = true }
                        }) {
                            HStack {
                                Image(systemName: "tray.and.arrow.down")
                                Text("Import M3U")
                            }
                        }
                        .padding(.horizontal)
                        .foregroundColor(.primary)
                        .buttonStyle(PlainButtonStyle())

                        Button(action: {
                            exportSelectedPlaylist()
                        }) {
                            HStack {
                                Image(systemName: "tray.and.arrow.up")
                                Text("Export M3U")
                            }
                        }
                        .padding(.horizontal)
                        .foregroundColor(selectedPlaylistID == nil ? .secondary : .primary)
                        .buttonStyle(PlainButtonStyle())
                        .disabled(selectedPlaylistID == nil)
                    }
                    .frame(height: 40)
                    .background(Color(nsColor: .windowBackgroundColor)) // Use system window background
                }
                .background(Color(nsColor: .windowBackgroundColor)) // Use system window background
                .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                    handleFileImport(result)
                }
                .onChange(of: showFileImporter) { isPresented in
                    guard isPresented else { return }
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = false
                    panel.prompt = "Choose"
                    panel.begin { response in
                        defer { self.showFileImporter = false }
                        if response == .OK, let url = panel.url {
                            self.handleFileImport(.success([url]))
                        }
                    }
                }
                .fileImporter(isPresented: $showM3UImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls):
                        var lastImportedID: UUID? = nil
                        for url in urls {
                            importPlaylistFromM3U(url: url)
                            // After importPlaylistFromM3U appends and selects, capture current selection
                            lastImportedID = selectedPlaylistID
                        }
                        // Keep the last imported playlist selected
                        if let last = lastImportedID {
                            selectedPlaylistID = last
                        }
                    case .failure(let error):
                        print("M3U import failed: \(error.localizedDescription)")
                    }
                }
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    print("Running loadSongsOnce at launch")
                    loadSongsOnce()
                    generateSystemPlaylists()
                    loadUserPlaylists()
                    setupRemoteCommands()
                    
                    restorePlaybackState()

                    // Stop security-scoped access cleanly when the app quits
                    NotificationCenter.default.addObserver(
                        forName: NSApplication.willTerminateNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        releaseFolderAccess()
                    }
                }
                .onDisappear {
                    // Clean up observers when window closes, but do not stop playback
                    if let token = timeObserverToken {
                        player?.removeTimeObserver(token)
                        timeObserverToken = nil
                    }
                    if let token = playbackEndObserver {
                        NotificationCenter.default.removeObserver(token)
                        playbackEndObserver = nil
                    }
                }
                .sheet(isPresented: $showNewPlaylistSheet) {
                    NewPlaylistSheet(playlists: $playlistManager.userPlaylists)
                        .onDisappear { saveUserPlaylists() }
                }
                .sheet(item: $songToAddToPlaylist) { song in
                    PlaylistSelectionView(song: song) { playlist in
                        playlistManager.addSong(song, to: playlist)
                        saveUserPlaylists()
                        songToAddToPlaylist = nil
                    }
                    .environmentObject(playlistManager)
                }
                .onChange(of: selectedSong) { newSong in
                    guard let song = newSong else { return }
                    incrementPlayCount(for: song)
                    generateSystemPlaylists()
                    refreshSongPlayCounts()
                    updateNowPlayingInfo()
                    updateUpcomingSongs()

                    // Load lyrics when song changes
                    if showLyrics {
                        loadLyrics(for: song)
                    }
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
                        playedShuffleSongs.removeAll()
                    }
                    updateUpcomingSongs()
                }
                .onChange(of: isRepeatOne) { _ in
                    updateUpcomingSongs()
                }
                .onChange(of: appAppearance) { _ in
                    // Update mini player appearance when app appearance changes
                    updateMiniPlayerAppearance()
                }
                .onChange(of: playlistManager.userPlaylists.map { $0.id }) { _ in
                    saveUserPlaylists()
                }
                .preferredColorScheme(appAppearance == "light" ? .light : appAppearance == "dark" ? .dark : nil)
                .focusedSceneValue(\.deletePlaylistAction, deletePlaylistAction())
            }
        }
    }

    private func deletePlaylistAction() -> (() -> Void)? {
        guard let playlistID = selectedPlaylistID,
              playlistManager.userPlaylists.contains(where: { $0.id == playlistID }) else {
            return nil
        }
        return {
            if let i = playlistManager.userPlaylists.firstIndex(where: { $0.id == playlistID }) {
                playlistManager.userPlaylists.remove(at: i)
                saveUserPlaylists()
                if selectedPlaylistID == playlistID {
                    selectedPlaylistID = nil
                    libraryActive = true
                }
            }
        }
    }

    private func releaseFolderAccess() {
        musicFolderAccess?.stopAccessingSecurityScopedResource()
        musicFolderAccess = nil
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let folderURL = urls.first {
                releaseFolderAccess()
                if folderURL.startAccessingSecurityScopedResource() {
                    do {
                        musicFolderAccess = folderURL
                        let bookmark = try folderURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                        musicFolderBookmarkData = bookmark
                        print("Saved security-scoped bookmark.")
                        Task {
                            let loaded = await loadSongs(from: folderURL)
                            await MainActor.run { songs = loaded }
                            generateSystemPlaylists()
                        }
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
                Task {
                    let loaded = await loadSongs(from: resolvedURL)
                    await MainActor.run {
                        songs = loaded
                        generateSystemPlaylists()
                    }
                }
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

        // Handle shuffle mode
        if isShuffleEnabled {
            // Only rebuild shuffle queue if we're not navigating backward or if it's the first song
            if !isNavigatingBackward {
                if playedShuffleSongs.isEmpty || playedShuffleSongs.last?.id != song.id {
                    rebuildShuffleQueue(startingFrom: song)
                }
            }
        } else {
            playedShuffleSongs.removeAll()
        }

        // Reset the backward navigation flag
        isNavigatingBackward = false

        setupNewPlayback(for: song)
        updateUpcomingSongs()

        // Load lyrics when playing a new song
        if showLyrics {
            loadLyrics(for: song)
        }
    }

    // New function to play a song from Up Next view
    private func playSongFromUpNext(_ song: Song) {
        playSong(song)
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
        // Removed isPlayingFlag = true

        player = newPlayer
        playerItem = item
        selectedSong = song
        playbackDuration = item.asset.duration.seconds
        playbackPosition = 0.0

        setupTimeObserver(for: newPlayer)
        setupPlaybackCompletionHandler(for: item)
        updateNowPlayingInfo()
        
        PersistentPlayer.shared.player = newPlayer
        PersistentPlayer.shared.selectedSong = song
    }

    private func stopCurrentPlayback() {
        player?.pause()
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }

        if let token = playbackEndObserver {
            NotificationCenter.default.removeObserver(token)
            playbackEndObserver = nil
        }

        playerItem = nil
        player = nil
        
        PersistentPlayer.shared.player = nil
        PersistentPlayer.shared.selectedSong = nil
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
        if let token = playbackEndObserver {
            NotificationCenter.default.removeObserver(token)
            playbackEndObserver = nil
        }
        playbackEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            if self.isRepeatOne {
                // Loop the same item by seeking to start and resuming playback
                self.player?.seek(to: .zero)
                self.player?.play()
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
                // If queue is empty but we have played songs, we can reshuffle
                if isRepeatEnabled || isRepeatOne {
                    // Rebuild the queue from the original playback context
                    let context = playbackContext(for: current)
                    let pool = context.filter { song in
                        // Check if song is not the current song and not in playedShuffleSongs
                        if song.id == current.id { return false }
                        return !playedShuffleSongs.contains { $0.id == song.id }
                    }
                    if !pool.isEmpty {
                        shuffleQueue = pool.shuffled()
                    } else {
                        // If all songs have been played, start fresh
                        rebuildShuffleQueue(startingFrom: current)
                    }
                } else {
                    // No more songs in queue and repeat is off
                    return
                }
            }

            if let next = shuffleQueue.first {
                shuffleQueue.removeFirst()
                playedShuffleSongs.append(next)
                playSong(next)
                return
            }
        }

        playNextSequentialSong(after: current)
    }

    private func playPrevious() {
        guard let current = selectedSong else { return }

        // Set the backward navigation flag
        isNavigatingBackward = true

        if isShuffleEnabled {
            if playedShuffleSongs.count > 1 {
                // Remove the current song from the end
                let justLeftSong = playedShuffleSongs.removeLast()
                // Get the previous song
                if let previousSong = playedShuffleSongs.last {
                    // Insert the song we just left at the front of the shuffleQueue
                    shuffleQueue.insert(justLeftSong, at: 0)
                    playSong(previousSong)
                    return
                }
            } else if playedShuffleSongs.count == 1 {
                // At the start of shuffle history: restart current song
                player?.seek(to: .zero)
                playbackPosition = 0.0
                updateNowPlayingPlaybackInfo()
                return
            }
            // If no history or only one song in history, play a random song
            playRandomSong(excluding: current)
            return
        }

        playPreviousSequentialSong(before: current)
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
                // Removed self.isPlayingFlag = true
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
                // Removed self.isPlayingFlag = false
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
                // Removed self.isPlayingFlag = true
            } else {
                player.pause()
                // Removed self.isPlayingFlag = false
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

        // Special case: if repeat one is enabled, don't show upcoming songs
        if isRepeatOne {
            upcomingSongs = []
            return
        }

        if isShuffleEnabled {
            // Show the next items from the persistent shuffle queue
            upcoming = Array(shuffleQueue.prefix(15))
        } else {
            // Get next sequential songs
            if let currentIndex = currentPlaybackSongs.firstIndex(where: { $0.id == current.id }) {
                let startIndex = currentIndex + 1
                let endIndex = min(startIndex + 15, currentPlaybackSongs.count) // Show up to 15 songs

                if startIndex < endIndex {
                    upcoming = Array(currentPlaybackSongs[startIndex..<endIndex])
                }

                // If we're near the end and repeat is enabled, add songs from the beginning
                if (isRepeatEnabled) && upcoming.count < 15 {
                    let additionalNeeded = 15 - upcoming.count
                    let additionalSongs = currentPlaybackSongs.prefix(additionalNeeded)
                    upcoming.append(contentsOf: additionalSongs)
                }
            }
        }

        upcomingSongs = upcoming
    }

    private func loadLyrics(for song: Song) {
        let asset = AVURLAsset(url: song.url)

        Task {
            do {
                let formats = try await asset.load(.availableMetadataFormats)
                var allItems: [AVMetadataItem] = []

                for format in formats {
                    let items = try await asset.loadMetadata(for: format)
                    allItems.append(contentsOf: items)
                }

                var foundLyrics: String? = nil

                for item in allItems {
                    // 1. Check the identifier (e.g., "id3/USLT")
                    let id = item.identifier?.rawValue ?? ""

                    // 2. Check the raw key (can be String or Number)
                    let keyAttribute = item.key as? String ?? ""

                    // 3. Common Key
                    let commonKey = item.commonKey?.rawValue ?? ""

                    if id.contains("USLT") || id.contains("©lyr") ||
                       keyAttribute.contains("USLT") ||
                       commonKey.lowercased().contains("lyrics") {

                        if let value = try await item.load(.value) as? String {
                            foundLyrics = value
                            break
                        }
                    }
                }

                await MainActor.run {
                    if let lyrics = foundLyrics {
                        self.lyricsText = lyrics.trimmingCharacters(in: .controlCharacters)
                    } else {
                        checkForExternalLRC(for: song)

                        // If no lyrics found locally, attempt to fetch from LRCLib
                        Task {
                            // Give checkForExternalLRC a moment to update state
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            if self.lyricsText == "No lyrics found." || self.lyricsText == "No lyrics found. Trying online..." {
                                if let fetched = await self.fetchLyricsFromLRCLib(for: song) {
                                    await MainActor.run { self.lyricsText = fetched }
                                } else {
                                    await MainActor.run {
                                        if self.lyricsText.isEmpty || self.lyricsText.contains("Trying online") {
                                            self.lyricsText = "No online lyrics found."
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                print("Extraction failed: \(error)")
                await MainActor.run { self.lyricsText = "Error loading metadata." }
            }
        }
    }

    private func checkForExternalLRC(for song: Song) {
        let lrcURL = song.url.deletingPathExtension().appendingPathExtension("lrc")

        let access = lrcURL.startAccessingSecurityScopedResource()
        defer { if access { lrcURL.stopAccessingSecurityScopedResource() } }

        if FileManager.default.fileExists(atPath: lrcURL.path) {
            do {
                self.lyricsText = try String(contentsOf: lrcURL, encoding: .utf8)
            } catch {
                self.lyricsText = "Found .lrc file but could not read it."
            }
        } else {
            self.lyricsText = "No lyrics found. Trying online..."
        }
    }

    private func fetchLyricsFromLRCLib(for song: Song) async -> String? {
        // Prepare a clean query (remove punctuation that can hurt matching)
        let rawQuery = "\(song.title) \(song.artist)"
        let cleaned = rawQuery.replacingOccurrences(of: ",", with: " ")
                              .replacingOccurrences(of: "(", with: " ")
                              .replacingOccurrences(of: ")", with: " ")
                              .replacingOccurrences(of: "[", with: " ")
                              .replacingOccurrences(of: "]", with: " ")
                              .replacingOccurrences(of: "  ", with: " ")
                              .trimmingCharacters(in: .whitespacesAndNewlines)

        let hosts = [
            "https://lrclib.net"
        ]

        // Common decode type
        struct LRCLibResult: Decodable { let syncedLyrics: String?; let plainLyrics: String? }

        for base in hosts {
            var components = URLComponents(string: base + "/api/search")
            components?.queryItems = [ URLQueryItem(name: "q", value: cleaned) ]
            guard let url = components?.url else { continue }

            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                let results = try JSONDecoder().decode([LRCLibResult].self, from: data)
                if let first = results.first {
                    if let plain = first.plainLyrics, !plain.isEmpty { return plain }
                    if let synced = first.syncedLyrics, !synced.isEmpty { return stripLRCTimestamps(from: synced) }
                }
            } catch {
                print("LRCLib fetch failed at \(base): \(error)")
                // Try next host
                continue
            }
        }

        // If all attempts failed
        await MainActor.run {
            if self.lyricsText.isEmpty || self.lyricsText.contains("Trying online") {
                self.lyricsText = "No online lyrics found."
            }
        }
        return nil
    }

    private func stripLRCTimestamps(from text: String) -> String {
        // Remove LRC headers like [ti:], [ar:], [al:], [by:], [offset:]
        let headerPattern = #"^\s*\[(ti|ar|al|by|offset):[^\]]*\]\s*$"#
        // Remove time tags like [mm:ss], [mm:ss.xx], [mm:ss.xxx]
        let timeTagPattern = #"\s*\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]\s*"#

        let lines = text.components(separatedBy: .newlines)
        let headerRegex = try? NSRegularExpression(pattern: headerPattern, options: [.anchorsMatchLines])
        let timeRegex = try? NSRegularExpression(pattern: timeTagPattern, options: [])

        let cleanedLines: [String] = lines.compactMap { line in
            var line = line
            // Skip pure header lines entirely
            if let headerRegex = headerRegex, headerRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                return nil
            }
            if let timeRegex = timeRegex {
                let range = NSRange(location: 0, length: (line as NSString).length)
                let mutable = NSMutableString(string: line)
                var offset = 0
                timeRegex.enumerateMatches(in: line, options: [], range: range) { match, _, _ in
                    if let match = match {
                        let r = NSRange(location: match.range.location - offset, length: match.range.length)
                        mutable.replaceCharacters(in: r, with: "")
                        offset += match.range.length
                    }
                }
                line = String(mutable)
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }

        return cleanedLines.joined(separator: "\n")
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
        // isPlayingFlag = (player?.rate != 0)

        // Hide main window
        if let mainWindow = NSApp.mainWindow {
            mainWindow.orderOut(nil)
        }

        // Create and show mini player window
        let miniPlayerView = MiniPlayerView(
            player: player,
            selectedSong: $selectedSong,
            isPlaying: Binding(get: { (player?.rate ?? 0) != 0 }, set: { shouldPlay in
                if shouldPlay { self.player?.play() } else { self.player?.pause() }
                self.updateNowPlayingInfo()
            }),
            volume: $volume,
            playbackPosition: $playbackPosition,
            playbackDuration: $playbackDuration,
            onPlayPause: {
                if self.player?.rate != 0 {
                    self.player?.pause()
                } else {
                    self.player?.play()
                }
                self.updateNowPlayingInfo()
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

        // Set the appearance based on appAppearance
        updateWindowAppearance(window)

        miniPlayerWindow = window

        // Set up notification to detect when mini player is closed
        miniPlayerCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            self.handleMiniPlayerClose()
        }
    }

    private func updateWindowAppearance(_ window: NSWindow) {
        switch appAppearance {
        case "light":
            window.appearance = NSAppearance(named: .aqua)
        case "dark":
            window.appearance = NSAppearance(named: .darkAqua)
        default:
            // System default
            window.appearance = nil
        }
    }

    private func updateMiniPlayerAppearance() {
        if let window = miniPlayerWindow {
            updateWindowAppearance(window)
        }
    }

    private func exportSelectedPlaylist() {
        guard let playlistID = selectedPlaylistID,
              let playlist = playlists.first(where: { $0.id == playlistID }) else {
            return
        }
        // Build M3U content
        let lines = buildM3UContent(for: playlist)
        let content = lines.joined(separator: "\n")

        // Ask user for save location using NSSavePanel
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["m3u", "m3u8"]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sanitizeFileName("\(playlist.name).m3u")
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    print("Failed to write M3U: \(error)")
                }
            }
        }
    }

    private func buildM3UContent(for playlist: Playlist) -> [String] {
        var lines: [String] = ["#EXTM3U"]
        for song in playlist.songs {
            let duration = -1 // Cant get the info, so uhh ignore it
            let title = song.title
            let artist = song.artist
            let display = artist.isEmpty ? title : "\(artist) - \(title)"
            lines.append("#EXTINF:\(duration),\(display)")
            // Prefer relative path if within the selected music folder access
            if let base = musicFolderAccess {
                let path = song.url.path
                let basePath = base.path
                if path.hasPrefix(basePath) {
                    let rel = String(path.dropFirst(basePath.count + (basePath.hasSuffix("/") ? 0 : 1)))
                    lines.append(rel)
                    continue
                }
            }
            lines.append(song.url.path)
        }
        return lines
    }

    private func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }

    // Normalize strings for more forgiving matching
    private func normalizeForMatching(_ s: String) -> String {
        // Normalize to NFC to avoid different Unicode compositions
        let nfc = s.precomposedStringWithCanonicalMapping
        // Remove diacritics and lowercase with locale-aware rules
        let folded = nfc.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        // Replace common separators with a space
        let replaced = folded
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "\u{2010}", with: " ") // hyphen
            .replacingOccurrences(of: "\u{2013}", with: " ") // en dash
            .replacingOccurrences(of: "\u{2014}", with: " ") // em dash
            .replacingOccurrences(of: "\u{2212}", with: " ") // minus sign
            .replacingOccurrences(of: "\u{2043}", with: " ") // hyphen bullet
            .replacingOccurrences(of: "\u{30A0}", with: " ") // katakana-hiragana double hyphen
        // Keep letters and numbers from all scripts plus whitespace
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(replaced.unicodeScalars.count)
        for sc in replaced.unicodeScalars {
            if CharacterSet.alphanumerics.contains(sc) || CharacterSet.whitespacesAndNewlines.contains(sc) {
                scalars.append(sc)
            }
        }
        let filtered = String(String.UnicodeScalarView(scalars))
        // Collapse whitespace
        let components = filtered.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return components.joined(separator: " ")
    }
    
    /// Parse M3U content into entries with optional EXTINF metadata
    private func parseM3UEntries(text: String, baseDirectory: URL) -> [(path: String, title: String?, artist: String?)] {
        // Normalize line endings and strip BOM
        var content = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if content.hasPrefix("\u{FEFF}") { content.removeFirst() }

        var entries: [(String, String?, String?)] = []
        var pendingTitle: String? = nil
        var pendingArtist: String? = nil

        for rawLine in content.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF:") {
                // Format: #EXTINF:duration,Title - Artist
                if let commaRange = line.range(of: ",") {
                    let meta = String(line[commaRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    // Split on common separators between Title and Artist
                    // Prefer "Title - Artist" ordering as in your sample
                    let seps = [" - ", " – ", " — ", " | ", " ~ ", " by "]
                    var t: String? = nil
                    var a: String? = nil
                    for sep in seps {
                        if let r = meta.range(of: sep, options: [.caseInsensitive]) {
                            t = String(meta[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                            a = String(meta[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                            break
                        }
                    }
                    pendingTitle = t ?? meta
                    pendingArtist = a
                }
                continue
            }
            if line.hasPrefix("#") { continue } // other comments

            // Path line
            // Remove optional surrounding quotes
            if line.hasPrefix("\"") && line.hasSuffix("\"") && line.count >= 2 {
                line = String(line.dropFirst().dropLast())
            }
            // Convert Windows backslashes
            line = line.replacingOccurrences(of: "\\", with: "/")
            // Percent decoding
            if let decoded = line.removingPercentEncoding {
                line = decoded
            } else if let url = URL(string: line), let decoded = url.path.removingPercentEncoding {
                line = decoded
            }
            // Precompose and tame excessive slashes
            line = line.precomposedStringWithCanonicalMapping
            if let regex = try? NSRegularExpression(pattern: #"/{3,}"#) {
                let ns = line as NSString
                let range = NSRange(location: 0, length: ns.length)
                line = regex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "//")
            }

            entries.append((line, pendingTitle, pendingArtist))
            pendingTitle = nil
            pendingArtist = nil
        }

        return entries
    }

    // Decode playlist data with best-effort encoding detection (handles non-Latin encodings)
    private func decodePlaylistText(from data: Data) -> String? {
        // Try automatic detection via NSString
        if let detected = NSString(data: data, encoding: String.Encoding.utf8.rawValue) as String? {
            return detected
        }

        // Common Unicode encodings with BOM or without
        let unicodeEncodings: [String.Encoding] = [
            .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32, .utf32LittleEndian, .utf32BigEndian
        ]
        for enc in unicodeEncodings {
            if let s = String(data: data, encoding: enc) { return s }
        }

        // Common legacy encodings used in Asian locales
        let legacyCandidates: [CFStringEncodings] = [
            .shiftJIS, // Japanese
            .GB_18030_2000, // Simplified Chinese
            .big5, // Traditional Chinese
            .EUC_KR // Korean
        ]
        for cfEnc in legacyCandidates {
            let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc.rawValue))
            let enc = String.Encoding(rawValue: nsEnc)
            if let s = String(data: data, encoding: enc) { return s }
        }

        // Treat bytes as the ISO-8859-1 and promote to Unicode
        if let s = String(data: data, encoding: .isoLatin1) { return s }

        return nil
    }

    private func importPlaylistFromM3U(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let text = decodePlaylistText(from: data) ?? (String(data: data, encoding: .utf8) ?? "")
            let baseDir = url.deletingLastPathComponent()
            // Replace parseM3U with parseM3UEntries
            let entries = parseM3UEntries(text: text, baseDirectory: baseDir)

            // Build fast lookup maps for name-based matching
            // Map normalized "title artist" -> [Song]
            var titleArtistMap: [String: [Song]] = [:]
            var titleOnlyMap: [String: [Song]] = [:]
            for s in songs {
                let titleNorm = normalizeForMatching(s.title)
                let artistNorm = normalizeForMatching(s.artist)
                let keyTA = (titleNorm + " " + artistNorm).trimmingCharacters(in: .whitespaces)
                if !keyTA.isEmpty {
                    titleArtistMap[keyTA, default: []].append(s)
                }
                if !titleNorm.isEmpty {
                    titleOnlyMap[titleNorm, default: []].append(s)
                }
            }

            // Helper to resolve a path string to an absolute URL
            func resolveURL(for path: String) -> URL {
                // If it's a file URL string
                if let u = URL(string: path), u.scheme == "file" {
                    return u.standardizedFileURL
                }

                // Expand tilde and standardize
                let expanded = (path as NSString).expandingTildeInPath

                // Absolute POSIX path
                if expanded.hasPrefix("/") {
                    let p = expanded.precomposedStringWithCanonicalMapping
                    return URL(fileURLWithPath: p).standardizedFileURL
                }

                // Relative path: prefer selected music folder if available
                if let base = musicFolderAccess {
                    let p = expanded.precomposedStringWithCanonicalMapping
                    return base.appendingPathComponent(p).standardizedFileURL
                } else {
                    let p = expanded.precomposedStringWithCanonicalMapping
                    return baseDir.appendingPathComponent(p).standardizedFileURL
                }
            }

            // Helper to derive best-guess title/artist from a filename
            func parseTitleArtist(from filename: String) -> (title: String, artist: String?) {
                let name = (filename as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping
                // Split on common separators
                let separators = [" - ", " – ", " — ", " | ", " ~ ", " by "]
                for sep in separators {
                    if let range = name.range(of: sep, options: [.caseInsensitive]) {
                        let left = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let right = String(name[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        // Heuristic: assume "Artist - Title" first
                        let artist = left
                        let title = right
                        return (title: title, artist: artist.isEmpty ? nil : artist)
                    }
                }
                // If no separator, return whole name as title
                return (title: name, artist: nil)
            }

            var importedSongs: [Song] = []
            var seenIDs = Set<UUID>()

            for entry in entries {
                let raw = entry.path
                let extTitle = entry.title
                let extArtist = entry.artist

                // Try direct file path match (standardized and resolving symlinks)
                // Do not attempt to remove the try catches. It will break
                let resolvedURL = resolveURL(for: raw).standardizedFileURL
                let targetResolved = (try? resolvedURL.resolvingSymlinksInPath()) ?? resolvedURL
                if let match = songs.first(where: { ($0.url.standardizedFileURL == targetResolved) || ((try? $0.url.resolvingSymlinksInPath()) == targetResolved) }) {
                    if !seenIDs.contains(match.id) {
                        importedSongs.append(match)
                        seenIDs.insert(match.id)
                    }
                    continue
                }

                // On case/diacritic-insensitive file systems, compare normalized paths as a fallback
                let targetPathNorm = targetResolved.path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if let match = songs.first(where: {
                    $0.url.path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == targetPathNorm
                }) {
                    if !seenIDs.contains(match.id) {
                        importedSongs.append(match)
                        seenIDs.insert(match.id)
                    }
                    continue
                }

                // 2) Try EXTINF-based matching (Title - Artist) if available
                if let t = extTitle {
                    let titleKey = normalizeForMatching(t)
                    var candidate: Song? = nil
                    if let a = extArtist {
                        let artistKey = normalizeForMatching(a)
                        let keyTA = (titleKey + " " + artistKey).trimmingCharacters(in: .whitespaces)
                        if let list = titleArtistMap[keyTA] { candidate = list.first }
                    }
                    if candidate == nil, let list = titleOnlyMap[titleKey] {
                        if list.count == 1 { candidate = list.first }
                    }
                    if let match = candidate, !seenIDs.contains(match.id) {
                        importedSongs.append(match)
                        seenIDs.insert(match.id)
                        continue
                    }
                }

                // 2) Fallback to name-based matching using filename
                let filename = (raw as NSString).lastPathComponent
                let guess = parseTitleArtist(from: filename)
                let titleKey = normalizeForMatching(guess.title)

                var candidate: Song? = nil

                if let artist = guess.artist {
                    let artistKey = normalizeForMatching(artist)
                    let keyTA = (titleKey + " " + artistKey).trimmingCharacters(in: .whitespaces)
                    if let list = titleArtistMap[keyTA] {
                        // Prefer exact artist+title match
                        candidate = list.first
                    }
                }

                if candidate == nil, let list = titleOnlyMap[titleKey] {
                    if list.count == 1 {
                        candidate = list.first
                    } else {
                        // Try to disambiguate using artist name present in the path
                        let loweredPath = normalizeForMatching(raw)
                        candidate = list.first { s in
                            let artistKey = normalizeForMatching(s.artist)
                            return !artistKey.isEmpty && loweredPath.contains(artistKey)
                        }
                        // As another fallback, try matching by filename against each song's URL (preserve non-Latin characters)
                        if candidate == nil {
                            let rawFilename = (raw as NSString).lastPathComponent
                            let rawPrecomposed = rawFilename.precomposedStringWithCanonicalMapping

                            // Exact case-sensitive match on precomposed strings
                            if let exact = songs.first(where: { $0.url.lastPathComponent.precomposedStringWithCanonicalMapping == rawPrecomposed }) {
                                candidate = exact
                            } else {
                                // Case and diacritic-insensitive match on precomposed strings
                                candidate = songs.first { s in
                                    let lhs = s.url.lastPathComponent.precomposedStringWithCanonicalMapping.folding(options: [.diacriticInsensitive], locale: .current)
                                    let rhs = rawPrecomposed.folding(options: [.diacriticInsensitive], locale: .current)
                                    return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
                                }
                            }
                        }
                    }
                }

                if let match = candidate, !seenIDs.contains(match.id) {
                    importedSongs.append(match)
                    seenIDs.insert(match.id)
                } else {
                    // Could not match this entry; skip silently.
                }
            }

            print("M3U import: matched \(importedSongs.count) of \(entries.count) entries")

            if importedSongs.isEmpty {
                print("No matching songs found for imported M3U.")
                return
            }

            // Ask user to create a new playlist name
            let defaultName = url.deletingPathExtension().lastPathComponent
            let newName = suggestUniquePlaylistName(basedOn: defaultName)
            let newPlaylist = Playlist(name: newName, songs: importedSongs, isSystem: false)
            playlistManager.userPlaylists.append(newPlaylist)
            saveUserPlaylists()
            selectedPlaylistID = newPlaylist.id
        } catch {
            print("Failed to read M3U: \(error)")
        }
    }

    private func parseM3U(text: String, baseDirectory: URL) -> [String] {
        var result: [String] = []
        var content = text
        // Normalize common line endings
        content = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Strip UTF-8 BOM if present
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }

        for rawLine in content.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue } // skip comments and #EXTINF

            // Remove optional surrounding quotes
            if line.hasPrefix("\"") && line.hasSuffix("\"") && line.count >= 2 {
                line = String(line.dropFirst().dropLast())
            }

            // Convert Windows backslashes to POSIX style
            line = line.replacingOccurrences(of: "\\", with: "/")

            // Decode percent-encoding if present
            if let decoded = line.removingPercentEncoding {
                line = decoded
            } else if let url = URL(string: line), let decoded = url.path.removingPercentEncoding {
                line = decoded
            }

            // Normalize Unicode composition for the path text
            line = line.precomposedStringWithCanonicalMapping
            // Avoid over-collapsing slashes; only reduce sequences of 3+ to 2, preserve scheme parts
            let slashPattern = #"/{3,}"#
            if let regex = try? NSRegularExpression(pattern: slashPattern) {
                let ns = line as NSString
                let range = NSRange(location: 0, length: ns.length)
                line = regex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "//")
            }

            result.append(line)
        }
        return result
    }

    private func suggestUniquePlaylistName(basedOn base: String) -> String {
        var name = base
        var suffix = 1
        while playlists.contains(where: { $0.name == name }) {
            suffix += 1
            name = "\(base) \(suffix)"
        }
        return name
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

        if let token = miniPlayerCloseObserver {
            NotificationCenter.default.removeObserver(token)
            miniPlayerCloseObserver = nil
        }
    }
}

struct UpNextView: View {
    let currentSong: Song?
    let upcomingSongs: [Song]
    let isPlaying: Bool
    var onSongSelect: (Song) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Up Next")
                .font(.headline)
                .padding(.horizontal)

            if let current = currentSong {
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
                    .onTapGesture {
                        onSongSelect(song)
                    }
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
        .background(Color(nsColor: .windowBackgroundColor)) // Use system window background
    }
}

// Lyrics view implementation
struct LyricsView: View {
    let currentSong: Song?
    let lyrics: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lyrics")
                .font(.headline)
                .padding(.horizontal)

            if let song = currentSong {
                HStack(spacing: 12) {
                    if let artworkData = song.artworkData,
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
                        Text(song.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(song.artist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        if !song.album.isEmpty {
                            Text(song.album)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal)

                Divider()
            }

            ScrollView {
                Text(lyrics)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding(.horizontal)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ITunesSidebarBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let top = colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 1.0))
            : Color(nsColor: NSColor(calibratedWhite: 0.97, alpha: 1.0))
        let bottom = colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(calibratedWhite: 0.90, alpha: 1.0))

        return LinearGradient(gradient: Gradient(colors: [top, bottom]), startPoint: .top, endPoint: .bottom)
            .overlay(
                Rectangle()
                    .fill(colorScheme == .dark ? Color.black.opacity(0.6) : Color.black.opacity(0.15))
                    .frame(width: 1),
                alignment: .trailing
            )
    }
}

