import SwiftUI
import AVFoundation
import Combine
import MediaPlayer
import UniformTypeIdentifiers

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
    // Songs explicitly queued by user (Play Next / drag-drop). Prepended by updateUpcomingSongs.
    @State private var manualQueue: [Song] = []
    @State private var shuffleQueue: [Song] = []
    @State private var playedShuffleSongs: [Song] = []
    @State private var isNavigatingBackward = false
    @State private var dropTargetIndex: Int? = nil

    // Lyrics states
    @State private var showLyrics = false
    @State private var lyricsText: String = ""

    @State private var showM3UExporter = false
    @State private var showM3UImporter = false
    @State private var m3UExportURL: URL?
    
    @State private var isDeviceSelected = false

    // Menu command support (File/Edit/View/Controls/Help)
    @FocusState private var isSearchFieldFocused: Bool
    @State private var volumeBeforeMute: Double = 0.5
    @State private var showKeyboardShortcuts = false

    @EnvironmentObject var deviceMonitor: iPodDeviceMonitor
    @EnvironmentObject var syncEngine: iPodSyncEngine

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
            if let d = selectedSong?.duration {
                playbackDuration = d
                playbackPosition = persistentPlayer.currentTime().seconds / max(playbackDuration, 0.1)
            } else {
                Task {
                    let seconds = (try? await currentItem.asset.load(.duration).seconds) ?? 0
                    await MainActor.run {
                        playbackDuration = seconds
                        playbackPosition = persistentPlayer.currentTime().seconds / max(playbackDuration, 0.1)
                    }
                }
            }
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

    // Insert one or more songs to play next
    private func addSongsNext(_ newSongs: [Song]) {
        // Prevent adding songs if Repeat One is active
        guard !isRepeatOne else { return }
        
        // Defer heavy array manipulation to let the UI (like context menus) dismiss smoothly
        DispatchQueue.main.async {
            let currentID = self.selectedSong?.id
            var seen = Set<UUID>()
            let filtered = newSongs.filter { s in
                guard s.id != currentID else { return false }
                if seen.contains(s.id) { return false }
                seen.insert(s.id)
                return true
            }
            guard !filtered.isEmpty else { return }

            if self.isShuffleEnabled {
                let ids = Set(filtered.map { $0.id })
                self.shuffleQueue.removeAll { ids.contains($0.id) }
                self.shuffleQueue.insert(contentsOf: filtered, at: 0)
            } else {
                // Store in manualQueue so updateUpcomingSongs() prepends them persistently
                let ids = Set(filtered.map { $0.id })
                self.manualQueue.removeAll { ids.contains($0.id) }
                self.manualQueue.insert(contentsOf: filtered, at: 0)
            }
            self.updateUpcomingSongs()
        }
    }
    
    // Called by UpNextView after it has already mutated upcomingSongs via the binding.
    // Mirror the reorder back into the authoritative queue (manualQueue or shuffleQueue).
    private func moveUpcomingSongs(from source: IndexSet, to destination: Int) {
        if isShuffleEnabled {
            // upcomingSongs == shuffleQueue.prefix(25); mirror the full reorder into shuffleQueue
            // Rebuild: take the reordered visible slice and splice it back into shuffleQueue
            let tail = shuffleQueue.count > upcomingSongs.count
                ? Array(shuffleQueue[upcomingSongs.count...])
                : []
            shuffleQueue = upcomingSongs + tail
        } else {
            manualQueue = upcomingSongs
        }
    }

    private func decodeSongs(from providers: [NSItemProvider], completion: @escaping ([Song]) -> Void) {
        let type = UTType.json.identifier
        var collected: [Song] = []
        let group = DispatchGroup()
        for p in providers where p.hasItemConformingToTypeIdentifier(type) {
            group.enter()
            p.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data {
                    if let s = try? JSONDecoder().decode(Song.self, from: data) {
                        collected.append(s)
                    } else if let list = try? JSONDecoder().decode([Song].self, from: data) {
                        collected.append(contentsOf: list)
                    }
                } else if let url = item as? URL, let data = try? Data(contentsOf: url) {
                    if let s = try? JSONDecoder().decode(Song.self, from: data) {
                        collected.append(s)
                    } else if let list = try? JSONDecoder().decode([Song].self, from: data) {
                        collected.append(contentsOf: list)
                    }
                }
            }
        }
        group.notify(queue: .main) { completion(collected) }
    }

    @ViewBuilder
    private func mainContentArea() -> some View {
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
                VStack(spacing: 0) {
                    // iTunes-style playlist header — only when a playlist is selected
                    // This thing kept showing up in the regular view T-T
                    if let playlistID = selectedPlaylistID,
                       let playlist = playlists.first(where: { $0.id == playlistID }) {
                        PlaylistHeaderView(
                            playlist: playlist,
                            onPlay: {
                                if let first = displayedSongs.first { playSong(first) }
                            },
                            onShuffle: {
                                isShuffleEnabled = true
                                if let random = displayedSongs.randomElement() { playSong(random) }
                            }
                        )
                        .id(playlist.id)
                        Divider()
                    }

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
                    .tint(.iTunesBlue)
                    // Do not remove below func. It breaks without it.
                    .ignoresSafeArea()
                }
            }
        }
    }

    var body: some View {
        Group {
            if isMiniPlayerActive {
                // Empty view when mini player is active
                EmptyView()
            } else {
                fullPlayerView
            }
        }
        .tint(.iTunesBlue)
    }

    /// The full (non-mini-player) layout, with all modifiers applied in
    /// separate chunks so the type checker solves each piece independently
    /// instead of one enormous chained expression.
    private var fullPlayerView: some View {
        let base = mainPlayerLayout
        let withImporters = applyImportersAndLifecycle(base)
        let withSheetsAndChanges = applySheetsAndChanges(withImporters)
        return applyFocusedSceneValues(withSheetsAndChanges)
    }

    private var mainPlayerLayout: some View {
        VStack(spacing: 0) {
            topToolbarSection
            Divider()
            middleContentSection
            Divider()
            bottomBarSection
        }
        .background(Color(nsColor: .windowBackgroundColor)) // Use system window background
    }

    private var topToolbarSection: some View {
        TopToolbarView(
            isAlbumView: $isAlbumView,
            showFileImporter: $showFileImporter,
            selectedSong: $selectedSong,
            isPlaying: isPlayingBinding,
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
            searchText: $searchText,
            searchFieldFocus: $isSearchFieldFocused
        )
    }

    private var middleContentSection: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 0) {
                SidebarView(
                    playlists: playlists,
                    userPlaylists: $playlistManager.userPlaylists,
                    selectedPlaylistID: $selectedPlaylistID,
                    showNewPlaylistSheet: $showNewPlaylistSheet,
                    libraryActive: $libraryActive,
                    showITunesStore: $showITunesStore,
                    //connectedDevice: deviceMonitor.connectedDevice,
                    isDeviceSelected: $isDeviceSelected
                )
                .frame(width: 220)
                .tint(.blue)
                .background(ITunesSidebarBackground())

                if let device = deviceMonitor.connectedDevice, isDeviceSelected {
                    iPodDeviceView(
                        device: device,
                        syncEngine: syncEngine,
                        allLibrarySongs: songs
                    )
                } else {
                    mainContentArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                }
            }

            if showUpNext {
                Divider()
                UpNextView(
                    currentSong: selectedSong,
                    upcomingSongs: $upcomingSongs,
                    isPlaying: (player?.rate ?? 0) > 0,
                    onSongSelect: playSongFromUpNext,
                    onMove: moveUpcomingSongs,
                    onDropSongs: addSongsNext
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
    }

    private var bottomBarSection: some View {
        HStack {
            Spacer()
            Button(action: toggleLyricsButtonAction) {
                HStack {
                    Image(systemName: "text.alignleft")
                    Text("lyrics.title")
                }
            }
            .padding(.horizontal)
            .foregroundColor(.primary)
            .buttonStyle(PlainButtonStyle())

            Button(action: toggleUpNextButtonAction) {
                HStack {
                    Image(systemName: "list.bullet")
                    Text("bottomBar.upNext")
                }
            }
            .padding(.horizontal)
            .foregroundColor(.primary)
            .buttonStyle(PlainButtonStyle())

            Button(action: showM3UImporterAction) {
                HStack {
                    Image(systemName: "tray.and.arrow.down")
                    Text("bottomBar.importM3U")
                }
            }
            .padding(.horizontal)
            .foregroundColor(.primary)
            .buttonStyle(PlainButtonStyle())

            Button(action: exportSelectedPlaylist) {
                HStack {
                    Image(systemName: "tray.and.arrow.up")
                    Text("bottomBar.exportM3U")
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

    private func showM3UImporterAction() {
        withAnimation { showM3UImporter = true }
    }

    @ViewBuilder
    private func applyImportersAndLifecycle<V: View>(_ content: V) -> some View {
        content
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false, onCompletion: handleFileImport)
            .onChange(of: showFileImporter, perform: handleShowFileImporterChange)
            .fileImporter(isPresented: $showM3UImporter, allowedContentTypes: [.data], allowsMultipleSelection: true, onCompletion: handleM3UImportResult)
            .frame(minWidth: 900, minHeight: 600)
            .onAppear(perform: handleContentViewAppear)
            .onDisappear(perform: handleContentViewDisappear)
    }

    @ViewBuilder
    private func applySheetsAndChanges<V: View>(_ content: V) -> some View {
        content
            .sheet(isPresented: $showNewPlaylistSheet) {
                NewPlaylistSheet(playlists: $playlistManager.userPlaylists)
                    .onDisappear(perform: saveUserPlaylists)
            }
            .sheet(item: $songToAddToPlaylist) { song in
                PlaylistSelectionView(song: song) { playlist in
                    self.handlePlaylistSelected(playlist, for: song)
                }
                .environmentObject(playlistManager)
            }
            .sheet(isPresented: $showKeyboardShortcuts) {
                KeyboardShortcutsView()
            }
            .onChange(of: selectedSong, perform: handleSelectedSongChange)
            .onChange(of: volume, perform: handleVolumeChange)
            .onChange(of: isShuffleEnabled, perform: handleShuffleEnabledChange)
            .onChange(of: isRepeatOne) { _ in updateUpcomingSongs() }
            .onChange(of: appAppearance) { _ in updateMiniPlayerAppearance() }
            .onChange(of: playlistManager.userPlaylists.map { $0.id }) { _ in saveUserPlaylists() }
            .onChange(of: deviceMonitor.connectedDevice) { device in
                if device == nil { isDeviceSelected = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AddToUpNextPlayNext")), perform: handleAddToUpNextNotification)
            .preferredColorScheme(appAppearance == "light" ? .light : appAppearance == "dark" ? .dark : nil)
    }

    @ViewBuilder
    private func applyFocusedSceneValues<V: View>(_ content: V) -> some View {
        content
            .focusedSceneValue(\.deletePlaylistAction, deletePlaylistAction())
            .focusedSceneValue(\.newPlaylistAction, newPlaylistAction)
            .focusedSceneValue(\.importMusicAction, importMusicAction)
            .focusedSceneValue(\.importPlaylistAction, importPlaylistAction)
            .focusedSceneValue(\.exportPlaylistAction, exportPlaylistMenuAction())
            .focusedSceneValue(\.focusSearchFieldAction, focusSearchFieldAction)
            .focusedSceneValue(\.showListViewAction, showListViewAction)
            .focusedSceneValue(\.showAlbumGridAction, showAlbumGridAction)
            .focusedSceneValue(\.showCoverFlowAction, showCoverFlowAction)
            .focusedSceneValue(\.toggleUpNextAction, toggleUpNextMenuAction)
            .focusedSceneValue(\.showUpNextValue, showUpNext)
            .focusedSceneValue(\.toggleLyricsAction, toggleLyricsMenuAction)
            .focusedSceneValue(\.showLyricsValue, showLyrics)
            .focusedSceneValue(\.toggleMiniPlayerAction, toggleMiniPlayer)
            .focusedSceneValue(\.togglePlayPauseAction, togglePlayPauseAction)
            .focusedSceneValue(\.isPlayingValue, player?.rate != 0)
            .focusedSceneValue(\.playNextAction, playNext)
            .focusedSceneValue(\.playPreviousAction, playPrevious)
            .focusedSceneValue(\.increaseVolumeAction, increaseVolumeAction)
            .focusedSceneValue(\.decreaseVolumeAction, decreaseVolumeAction)
            .focusedSceneValue(\.toggleMuteAction, toggleMuteAction)
            .focusedSceneValue(\.isMutedValue, volume == 0)
            .focusedSceneValue(\.toggleShuffleAction, toggleShuffleAction)
            .focusedSceneValue(\.isShuffleValue, isShuffleEnabled)
            .focusedSceneValue(\.cycleRepeatModeAction, cycleRepeatModeAction)
            .focusedSceneValue(\.isRepeatAllValue, isRepeatEnabled)
            .focusedSceneValue(\.isRepeatOneValue, isRepeatOne)
            .focusedSceneValue(\.showKeyboardShortcutsAction, showKeyboardShortcutsAction)
    }

    private func newPlaylistAction() {
        showNewPlaylistSheet = true
    }

    private func importMusicAction() {
        showFileImporter = true
    }

    private func importPlaylistAction() {
        showM3UImporter = true
    }

    private func exportPlaylistMenuAction() -> (() -> Void)? {
        guard selectedPlaylistID != nil else { return nil }
        return { exportSelectedPlaylist() }
    }

    private func focusSearchFieldAction() {
        isSearchFieldFocused = true
    }

    private func showListViewAction() {
        isAlbumView = false
        isCoverFlowActive = false
    }

    private func showAlbumGridAction() {
        isAlbumView = true
        isCoverFlowActive = false
    }

    private func showCoverFlowAction() {
        isCoverFlowActive = true
        isAlbumView = false
    }

    private func toggleUpNextMenuAction() {
        withAnimation {
            showUpNext.toggle()
            if showUpNext {
                updateUpcomingSongs()
            }
        }
    }

    private func toggleLyricsMenuAction() {
        withAnimation {
            showLyrics.toggle()
            if showLyrics, let song = selectedSong {
                loadLyrics(for: song)
            }
        }
    }

    private func togglePlayPauseAction() {
        if player?.rate != 0 {
            player?.pause()
        } else {
            player?.play()
            updateNowPlayingInfo()
        }
    }

    private func increaseVolumeAction() {
        volume = min(1.0, volume + 0.1)
    }

    private func decreaseVolumeAction() {
        volume = max(0.0, volume - 0.1)
    }

    private func toggleMuteAction() {
        if volume > 0 {
            volumeBeforeMute = volume
            volume = 0
        } else {
            volume = volumeBeforeMute > 0 ? volumeBeforeMute : 0.5
        }
    }

    private func toggleShuffleAction() {
        isShuffleEnabled.toggle()
    }

    private func cycleRepeatModeAction() {
        if !isRepeatEnabled && !isRepeatOne {
            isRepeatEnabled = true
            isRepeatOne = false
        } else if isRepeatEnabled && !isRepeatOne {
            isRepeatEnabled = false
            isRepeatOne = true
        } else {
            isRepeatEnabled = false
            isRepeatOne = false
        }
    }

    private func deletePlaylistAction() -> (() -> Void)? {
        guard let playlistID = selectedPlaylistID,
              playlistManager.userPlaylists.contains(where: { $0.id == playlistID }) else {
            return nil
        }
        return {
            if let i = playlistManager.userPlaylists.firstIndex(where: { $0.id == playlistID }) {
                PlaylistArtworkStore.shared.delete(for: playlistID)
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

    private func handleContentViewAppear() {
        print("Running loadSongsOnce at launch")
        loadSongsOnce()
        loadUserPlaylists()
        setupRemoteCommands()

        restorePlaybackState()

        // Stop security-scoped access cleanly when the app quits
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main,
            using: handleWillTerminate
        )
    }

    private func handleContentViewDisappear() {
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

    private func handleWillTerminate(_ notification: Notification) {
        releaseFolderAccess()
    }

    private var isPlayingBinding: Binding<Bool> {
        Binding(
            get: { player?.rate != 0 },
            set: { shouldPlay in
                if shouldPlay {
                    player?.play()
                    updateNowPlayingInfo()
                } else {
                    player?.pause()
                }
            }
        )
    }

    private func toggleLyricsButtonAction() {
        withAnimation {
            showLyrics.toggle()
            if showLyrics, let song = selectedSong {
                loadLyrics(for: song)
            }
        }
    }

    private func toggleUpNextButtonAction() {
        withAnimation {
            showUpNext.toggle()
            if showUpNext {
                updateUpcomingSongs()
            }
        }
    }

    private func handleShowFileImporterChange(_ isPresented: Bool) {
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

    private func handlePlaylistSelected(_ playlist: Playlist, for song: Song) {
        playlistManager.addSong(song, to: playlist)
        saveUserPlaylists()
        songToAddToPlaylist = nil
    }

    private func handleSelectedSongChange(_ newSong: Song?) {
        guard let song = newSong else { return }
        incrementPlayCount(for: song)
        refreshSongPlayCounts()
        generateSystemPlaylists()
        updateNowPlayingInfo()
        updateUpcomingSongs()

        // Load lyrics when song changes
        if showLyrics {
            loadLyrics(for: song)
        }
    }

    private func handleVolumeChange(_ newVolume: Double) {
        player?.volume = Float(newVolume)
        updateNowPlayingInfo()
    }

    private func handleShuffleEnabledChange(_ enabled: Bool) {
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

    private func handleAddToUpNextNotification(_ output: Notification) {
        if let song = output.object as? Song {
            addSongsNext([song])
        }
    }

    private func showKeyboardShortcutsAction() {
        showKeyboardShortcuts = true
    }

    private func handleM3UImportResult(_ result: Result<[URL], Error>) {
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
                            await MainActor.run {
                                songs = loaded
                                refreshSongPlayCounts()
                                generateSystemPlaylists()
                            }
                        }
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
                        refreshSongPlayCounts()
                        generateSystemPlaylists()
                    }
                }
                print("Successfully loaded songs from bookmark.")
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
        // Remove from whichever queue is authoritative so it isn't played again
        manualQueue.removeAll { $0.id == song.id }
        shuffleQueue.removeAll { $0.id == song.id }
        // Skip the shuffle rebuild that playSong would normally trigger —
        // the queue was already ordered by the user; preserve it.
        playedShuffleSongs.append(song)
        setupNewPlayback(for: song)
        updateUpcomingSongs()
        if showLyrics { loadLyrics(for: song) }
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

        if let d = song.duration {
            playbackDuration = d
        } else {
            Task {
                let seconds = (try? await item.asset.load(.duration).seconds) ?? 0
                await MainActor.run { playbackDuration = seconds }
            }
        }

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

        // If there is a manually queued song at front, consume it first
        if !isShuffleEnabled && !manualQueue.isEmpty {
            let next = manualQueue.removeFirst()
            playSong(next)
            return
        }

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
            generateTopPlayedPlaylist(from: uniqueSongs),
            generate90sMusicPlaylist(from: uniqueSongs),
            generateClassicalMusicPlaylist(from: uniqueSongs),
            generateRecentlyAddedPlaylist(from: uniqueSongs)
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

    private func generate90sMusicPlaylist(from songs: [Song]) -> Playlist {
        let nineties = songs.filter { song in
            if let yearStr = song.year, let year = Int(yearStr.prefix(4)) {
                return year >= 1990 && year <= 1999
            }
            return false
        }
        let sorted = nineties.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        return Playlist(name: "90s Music", songs: sorted, isSystem: true)
    }

    private func generateClassicalMusicPlaylist(from songs: [Song]) -> Playlist {
        let classical = songs.filter { song in
            let genre = song.genre
            return genre.localizedCaseInsensitiveContains("classical") ||
                   genre.localizedCaseInsensitiveContains("classic") ||
                   genre.localizedCaseInsensitiveContains("orchestra") ||
                   genre.localizedCaseInsensitiveContains("symphon") ||
                   genre.localizedCaseInsensitiveContains("chamber") ||
                   genre.localizedCaseInsensitiveContains("opera")
        }
        let sorted = classical.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        return Playlist(name: "Classical Music", songs: sorted, isSystem: true)
    }

    private func generateRecentlyAddedPlaylist(from songs: [Song]) -> Playlist {
        let fm = FileManager.default
        let withDates: [(song: Song, date: Date)] = songs.compactMap { song in
            guard let attrs = try? fm.attributesOfItem(atPath: song.url.path),
                  let created = attrs[.creationDate] as? Date else { return nil }
            return (song, created)
        }
        let sorted = withDates
            .sorted { $0.date > $1.date }
            .prefix(25)
            .map { $0.song }
        return Playlist(name: "Recently Added", songs: sorted, isSystem: true)
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

        // If in "Repeat One" mode, the queue should be empty
        if isRepeatOne {
            upcomingSongs = []
            return
        }
        
        if isShuffleEnabled {
            // Shuffle queue already reflects manual insertions; just show its front
            upcomingSongs = Array(shuffleQueue.prefix(25))
            return
        }

        // Non-shuffle: build computed "what comes next in the library" list
        var computed: [Song] = []
        if let currentIndex = currentPlaybackSongs.firstIndex(where: { $0.id == current.id }) {
            let startIndex = currentIndex + 1
            let endIndex = min(startIndex + 25, currentPlaybackSongs.count)
            if startIndex < endIndex {
                computed = Array(currentPlaybackSongs[startIndex..<endIndex])
            }
            if isRepeatEnabled && computed.count < 25 {
                let needed = 25 - computed.count
                computed.append(contentsOf: currentPlaybackSongs.prefix(needed))
            }
        }

        // Prepend manualQueue, then fill with computed songs that aren't already in manual queue
        let manualIDs = Set(manualQueue.map { $0.id })
        let filteredComputed = computed.filter { !manualIDs.contains($0.id) }
        upcomingSongs = manualQueue + filteredComputed
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
        guard selectedSong != nil else { return }

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
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u"), UTType(filenameExtension: "m3u8")].compactMap { $0 }
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
                let targetResolved = (resolvedURL.resolvingSymlinksInPath())
                if let match = songs.first(where: { ($0.url.standardizedFileURL == targetResolved) || (($0.url.resolvingSymlinksInPath()) == targetResolved) }) {
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

// Separate UTType identifier for internal reorder drags so they don't collide with Song JSON drops

struct UpNextView: View {
    let currentSong: Song?
    @Binding var upcomingSongs: [Song]
    let isPlaying: Bool
    var onSongSelect: (Song) -> Void = { _ in }
    var onMove: (IndexSet, Int) -> Void = { _, _ in }
    var onDropSongs: ([Song]) -> Void = { _ in }

    @State private var draggingIndex: Int = -1
    @State private var insertionIndex: Int? = nil
    @State private var externalDropHovering: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Now Playing")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if let current = currentSong {
                HStack(spacing: 12) {
                    artworkView(for: current, size: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.title).font(.headline).lineLimit(1)
                        Text(current.artist).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "speaker.wave.2.fill").foregroundColor(.blue)
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
                Divider()
            }

            if !upcomingSongs.isEmpty {
                Text("Next Up")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        dropZone(at: 0)

                        ForEach(Array(upcomingSongs.enumerated()), id: \.element.id) { index, song in
                            UpNextSongBlock(song: song, index: index, isDragging: draggingIndex == index)
                                .onTapGesture { onSongSelect(song) }
                                .onDrag {
                                    draggingIndex = index
                                    let data = "\(index)".data(using: .utf8) ?? Data()
                                    return NSItemProvider(item: data as NSData, typeIdentifier: UTType.plainText.identifier)
                                }
                            dropZone(at: index + 1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                }
                .onDrop(of: [UTType.json], isTargeted: $externalDropHovering) { providers in
                    handleExternalDrop(providers: providers)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .opacity(externalDropHovering ? 1 : 0)
                        .padding(4)
                )

            } else if isPlaying {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor.opacity(externalDropHovering ? 1 : 0.35), lineWidth: 1.5)
                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("No upcoming songs")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("Drag songs here to queue them")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .onDrop(of: [UTType.json], isTargeted: $externalDropHovering) { providers in
                    handleExternalDrop(providers: providers)
                }
            } else {
                VStack(spacing: 12) {
                    Image("Icon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .opacity(0.9)
                    Text("No song playing")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Drop zone strip between rows

    @ViewBuilder
    private func dropZone(at index: Int) -> some View {
        let isActive = insertionIndex == index
        ZStack {
            // Tall invisible hit area
            Rectangle()
                .fill(Color.clear)
                .frame(height: 12)
            // Visible accent line when active
            if isActive {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.plainText],
            isTargeted: Binding(
                get: { insertionIndex == index },
                set: { active in
                    if active { insertionIndex = index }
                    else if insertionIndex == index { insertionIndex = nil }
                }
            )
        ) { providers in
            handleReorderDrop(providers: providers, targetIndex: index)
        }
    }

    // MARK: - Artwork helper

    @ViewBuilder
    private func artworkView(for song: Song, size: CGFloat) -> some View {
        Group {
            if let data = song.artworkData, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image("Icon").resizable().aspectRatio(contentMode: .fill).opacity(0.9)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.1))
    }

    // MARK: - Drop handlers

    private func handleReorderDrop(providers: [NSItemProvider], targetIndex: Int) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) else { return false }

        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let raw: String?
            if let d = item as? Data { raw = String(data: d, encoding: .utf8) }
            else if let s = item as? String { raw = s }
            else { raw = nil }

            guard let src = raw.flatMap(Int.init) else { return }

            DispatchQueue.main.async {
                draggingIndex = -1
                insertionIndex = nil
                // Destination after accounting for removal of source
                let dest: Int
                if src < targetIndex {
                    dest = targetIndex - 1  // shifting down: target shifts left after removal
                } else if src == targetIndex || src == targetIndex - 1 {
                    return  // no-op, already in position
                } else {
                    dest = targetIndex
                }
                var arr = upcomingSongs
                arr.move(fromOffsets: IndexSet(integer: src), toOffset: dest)
                upcomingSongs = arr
                onMove(IndexSet(integer: src), dest)
            }
        }
        return true
    }

    private func handleExternalDrop(providers: [NSItemProvider]) -> Bool {
        let type = UTType.json.identifier
        var collected: [Song] = []
        let group = DispatchGroup()

        for p in providers where p.hasItemConformingToTypeIdentifier(type) {
            group.enter()
            p.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                defer { group.leave() }
                let data: Data?
                if let d = item as? Data { data = d }
                else if let url = item as? URL { data = try? Data(contentsOf: url) }
                else { data = nil }
                guard let d = data else { return }
                if let s = try? JSONDecoder().decode(Song.self, from: d) { collected.append(s) }
                else if let list = try? JSONDecoder().decode([Song].self, from: d) { collected.append(contentsOf: list) }
            }
        }

        group.notify(queue: .main) {
            guard !collected.isEmpty else { return }
            onDropSongs(collected)
        }
        return true
    }
}

// Song block card used in the Up Next queue
private struct UpNextSongBlock: View {
    let song: Song
    let index: Int
    let isDragging: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 18, alignment: .trailing)

            Group {
                if let data = song.artworkData, let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image("Icon").resizable().aspectRatio(contentMode: .fill).opacity(0.9)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.subheadline).lineLimit(1).truncationMode(.tail)
                Text(song.artist).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal").font(.caption).foregroundColor(.secondary).opacity(0.5)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDragging
                    ? Color.accentColor.opacity(0.12)
                    : Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 1 : 0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDragging ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1.5)
        )
        .opacity(isDragging ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.12), value: isDragging)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}


// Lyrics view implementation
struct LyricsView: View {
    let currentSong: Song?
    let lyrics: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("bottomBar.lyrics")
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
                        Image("Icon")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .opacity(0.9)
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
