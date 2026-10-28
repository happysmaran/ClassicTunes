import SwiftUI
import AVFoundation
import Combine
import MediaPlayer
import UniformTypeIdentifiers

// Main Application Manager

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
    @State private var albumListCache = AlbumListCache()
    @ObservedObject private var engine = PlayerEngine.shared
    @AppStorage("appAppearance") private var appAppearance: String = "system" // "system", "light", or "dark"
    @State private var isStopped = false
    @State private var systemPlaylists: [Playlist] = []
    @State private var selectedPlaylistID: UUID?
    @State private var libraryActive: Bool = true
    @State private var searchText: String = ""
    @State private var showITunesStore: Bool = false

    @State private var showNewPlaylistSheet = false
    @State private var showNewSmartPlaylistSheet = false
    @State private var smartPlaylistToEdit: Playlist?
    @StateObject private var playlistManager = PlaylistManager()
    
    // Playlist selection
    @State private var showPlaylistSelectionSheet = false
    @State private var songToAddToPlaylist: Song?

    // Song metadata editing
    @State private var songForInfo: Song?

    // MiniPlayer states
    @AppStorage("isMiniPlayerActive") private var isMiniPlayerActive = false
    @State private var miniPlayerWindow: NSWindow?

    // Observer tokens
    @State private var miniPlayerCloseObserver: NSObjectProtocol?

    // Sidebar artwork drawer and library stats
    @State private var showArtworkPane = false
    @State private var displayedTotalBytes = 0

    // Up Next states
    @State private var showUpNext = false
    @State private var dropTargetIndex: Int? = nil

    // Lyrics states
    @State private var showVisualizer = false
    @State private var showLyrics = false
    @State private var lyricsText: String = ""

    @State private var showM3UExporter = false
    @State private var showM3UImporter = false
    @State private var m3UExportURL: URL?
    
    @State private var isDeviceSelected = false

    // Menu command support
    @FocusState private var isSearchFieldFocused: Bool
    @State private var volumeBeforeMute: Double = 0.5
    @State private var showKeyboardShortcuts = false

    @EnvironmentObject var deviceMonitor: iPodDeviceMonitor
    @EnvironmentObject var syncEngine: iPodSyncEngine
    @EnvironmentObject var appearanceManager: AppearanceManager

    private var playlists: [Playlist] {
        playlistManager.userPlaylists + systemPlaylists
    }

    // Looks up a playlist by ID. Smart playlists are evaluated against the current library here,
    // so display, playback and M3U export all see their live song list.
    private func playlist(withID id: UUID) -> Playlist? {
        playlists.first(where: { $0.id == id })?.resolved(against: songs)
    }

    // Inserts a new smart playlist or replaces the edited one, then persists.
    private func saveSmartPlaylist(_ playlist: Playlist) {
        if let index = playlistManager.userPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            playlistManager.userPlaylists[index] = playlist
        } else {
            playlistManager.userPlaylists.append(playlist)
        }
        saveUserPlaylists()
        selectedPlaylistID = playlist.id
        libraryActive = false
        showITunesStore = false
    }

    // Playlist persistence lives in `PlaylistStore` (via `PlaylistManager`), which also handles the
    // legacy UserDefaults migration, backups and unreadable files.
    private func saveUserPlaylists() {
        playlistManager.savePlaylists()
    }
    
    private var displayedSongs: [Song] {
        // Build base list depending on selected playlist or full library
        let baseUnfiltered: [Song]
        if let playlistID = selectedPlaylistID,
           let playlist = playlist(withID: playlistID) {
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

    // Unique, sorted albums for Cover Flow. Memoized so artwork/grouping work
    // only reruns when the displayed library actually changes.
    private func albumsForCoverFlow(from displayed: [Song]) -> [AlbumInfo] {
        albumListCache.albums(for: displayed)
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
            } else if showVisualizer {
                VisualizerView()
            } else if isCoverFlowActive {
                // Evaluate the (deduped/filtered) song list once per render.
                let displayed = displayedSongs
                CoverFlowView(
                    albums: albumsForCoverFlow(from: displayed),
                    selectedAlbum: .constant(engine.selectedSong?.album ?? ""),
                    isCoverFlowActive: $isCoverFlowActive,
                    onAlbumSelect: { albumName in
                        let albumSongs = displayedSongs.filter { $0.album == albumName }
                        if let firstSong = albumSongs.first {
                            playSong(firstSong)
                        }
                    },
                    songs: displayed,
                    selectedSong: $engine.selectedSong,
                    currentPlaybackSongs: $engine.currentPlaybackSongs,
                    shuffleQueue: $engine.shuffleQueue,
                    isShuffleEnabled: $engine.isShuffleEnabled,
                    isRepeatOne: $engine.isRepeatOne,
                    isRepeatEnabled: $engine.isRepeatEnabled
                )
            } else {
                VStack(spacing: 0) {
                    // iTunes-style playlist header — only when a playlist is selected
                    // This thing kept showing up in the regular view T-T
                    if let playlistID = selectedPlaylistID,
                       let playlist = playlist(withID: playlistID) {
                        PlaylistHeaderView(
                            playlist: playlist,
                            onPlay: {
                                if let first = displayedSongs.first { playSong(first) }
                            },
                            onShuffle: {
                                engine.isShuffleEnabled = true
                                if let random = displayedSongs.randomElement() { playSong(random) }
                            }
                        )
                        .id(playlist.id)
                        Divider()
                    }

                    SongListView(
                        isAlbumView: isAlbumView,
                        songs: displayedSongs,
                        onSongSelect: engine.playSong,
                        selectedSong: $engine.selectedSong,
                        onAlbumSelect: { album in
                            let albumSongs = songs.filter { $0.album == album }
                            if let firstSong = albumSongs.first {
                                playSong(firstSong)
                            }
                        },
                        playlistSongs: selectedPlaylistID != nil ? displayedSongs : nil,
                        onAddToPlaylist: { song in
                            songToAddToPlaylist = song
                        },
                        onShowInfo: { song in
                            songForInfo = song
                        }
                    )
                    .environmentObject(playlistManager)
                    .tint(appearanceManager.themeColor)
                    // Do not remove below func. It breaks without it.
                    .ignoresSafeArea()
                }
            }
        }
    }

    var body: some View {
        // The full player stays in the hierarchy while the mini player is active (its window is
        // just hidden), so view state such as the highlighted row survives the round trip.
        fullPlayerView
            .tint(appearanceManager.themeColor)
            .task {
                for await _ in NotificationCenter.default.notifications(named: .toggleMiniPlayerRequested) {
                    toggleMiniPlayer()
                }
            }
    }

    // The full (non-mini-player) layout, with all modifiers applied in
    // separate chunks so the type checker solves each piece independently
    // instead of one enormous chained expression.
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
            selectedSong: $engine.selectedSong,
            isPlaying: isPlayingBinding,
            playPrevious: engine.playPrevious,
            playNext: engine.playNext,
            volume: $engine.volume,
            clock: engine.clock,
            playbackDuration: $engine.playbackDuration,
            onSeek: engine.handleSeek,
            isSeeking: $engine.isSeeking,
            isShuffleEnabled: $engine.isShuffleEnabled,
            isRepeatEnabled: $engine.isRepeatEnabled,
            isRepeatOne: $engine.isRepeatOne,
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
                VStack(spacing: 0) {
                    SidebarView(
                        playlists: playlists,
                        userPlaylists: $playlistManager.userPlaylists,
                        selectedPlaylistID: $selectedPlaylistID,
                        showNewPlaylistSheet: $showNewPlaylistSheet,
                        showNewSmartPlaylistSheet: $showNewSmartPlaylistSheet,
                        smartPlaylistToEdit: $smartPlaylistToEdit,
                        libraryActive: $libraryActive,
                        showITunesStore: $showITunesStore,
                        //connectedDevice: deviceMonitor.connectedDevice,
                        isDeviceSelected: $isDeviceSelected
                    )
                    .tint(appearanceManager.themeColor)

                    if showArtworkPane {
                        Divider()
                        sidebarArtworkPane
                    }
                }
                .frame(width: 220)
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
                    currentSong: engine.selectedSong,
                    upcomingSongs: $engine.upcomingSongs,
                    isPlaying: (engine.player?.rate ?? 0) > 0,
                    onSongSelect: engine.playSongFromUpNext,
                    onMove: engine.moveUpcomingSongs,
                    onDropSongs: engine.addSongsNext
                )
                .frame(width: 300)
            }

            if showLyrics {
                Divider()
                LyricsView(
                    currentSong: engine.selectedSong,
                    lyrics: lyricsText
                )
                .frame(width: 300)
            }
        }
    }

    // Artwork for the current song, shown in a drawer at the bottom of the sidebar.
    private var sidebarArtworkPane: some View {
        Group {
            if let image = engine.selectedSong?.artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.15))
            }
        }
        // Thin frame around the artwork.
        .overlay(Rectangle().stroke(Color.primary.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .padding(10)
        .frame(width: 220, height: 220)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // "# songs, #.# hours, #.## GB" for the songs currently shown.
    private func libraryStatsText(for displayed: [Song]) -> String {
        let count = displayed.count
        let hours = displayed.reduce(0) { $0 + ($1.duration ?? 0) } / 3600
        let gigabytes = Double(displayedTotalBytes) / 1_000_000_000
        let key = count == 1 ? "library.stats.one" : "library.stats.other"
        return String(format: NSLocalizedString(key, comment: "Bottom bar: song count, total hours, total size"),
                      count, hours, gigabytes)
    }

    private var bottomBarSection: some View {
        let displayed = displayedSongs
        let statsKey = displayed.map(\.id).hashValue
        return ZStack {
            HStack(spacing: 0) {
            Button(action: toggleArtworkPaneAction) {
                // One fixed symbol that rotates 180° so it turns instead of cross-fading.
                Image(systemName: "chevron.up")
                    .rotationEffect(.degrees(showArtworkPane ? 180 : 0))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .padding(.leading)
            .foregroundColor(showArtworkPane ? appearanceManager.themeColor : .primary)
            .buttonStyle(PlainButtonStyle())
            .help("Show or hide album artwork")

            Spacer()
            Button(action: toggleVisualizerMenuAction) {
                HStack {
                    Image(systemName: "waveform")
                    Text("bottomBar.visualizer")
                }
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .foregroundColor(showVisualizer ? appearanceManager.themeColor : .primary)
            .buttonStyle(PlainButtonStyle())

            Button(action: toggleLyricsButtonAction) {
                HStack {
                    Image(systemName: "text.alignleft")
                    Text("lyrics.title")
                }
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .foregroundColor(showLyrics ? appearanceManager.themeColor : .primary)
            .buttonStyle(PlainButtonStyle())

            Button(action: toggleUpNextButtonAction) {
                HStack {
                    Image(systemName: "list.bullet")
                    Text("bottomBar.upNext")
                }
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .foregroundColor(showUpNext ? appearanceManager.themeColor : .primary)
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 8)
            }

            // Centered on the window's width, independent of the buttons on either side.
            Text(libraryStatsText(for: displayed))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .allowsHitTesting(false)
                .task(id: statsKey) {
                    let urls = displayed.map(\.url)
                    displayedTotalBytes = await Task.detached(priority: .utility) {
                        urls.reduce(0) { total, url in
                            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                        }
                    }.value
                }
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
            .onChange(of: showFileImporter) { _, isPresented in handleShowFileImporterChange(isPresented) }
            .fileImporter(isPresented: $showM3UImporter, allowedContentTypes: [.data], allowsMultipleSelection: true, onCompletion: handleM3UImportResult)
            .frame(minWidth: 900, minHeight: 600)
            .onAppear(perform: handleContentViewAppear)
            .onDisappear(perform: handleContentViewDisappear)
    }

    @ViewBuilder
    private func applySheetsAndChanges<V: View>(_ content: V) -> some View {
        content
            .sheet(isPresented: $showNewPlaylistSheet) {
                NewPlaylistSheet(playlists: $playlistManager.userPlaylists, onSaveSmart: saveSmartPlaylist)
                    .onDisappear(perform: saveUserPlaylists)
            }
            .sheet(isPresented: $showNewSmartPlaylistSheet) {
                SmartPlaylistEditorSheet(onSave: saveSmartPlaylist)
            }
            .sheet(item: $smartPlaylistToEdit) { playlist in
                SmartPlaylistEditorSheet(existing: playlist, onSave: saveSmartPlaylist)
            }
            .sheet(item: $songToAddToPlaylist) { song in
                PlaylistSelectionView(song: song) { playlist in
                    self.handlePlaylistSelected(playlist, for: song)
                }
                .environmentObject(playlistManager)
            }
            .sheet(item: $songForInfo) { song in
                SongInfoView(song: song) { updated in
                    applyMetadataUpdate(updated)
                }
            }
            .sheet(isPresented: $showKeyboardShortcuts) {
                KeyboardShortcutsView()
            }
            .onChange(of: appAppearance) { updateMiniPlayerAppearance() }
            .onChange(of: playlistManager.userPlaylists.map { $0.id }) { saveUserPlaylists() }
            .onChange(of: deviceMonitor.connectedDevice) { _, device in
                if device == nil { isDeviceSelected = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AddToUpNextPlayNext")), perform: handleAddToUpNextNotification)
            .onReceive(NotificationCenter.default.publisher(for: .ChooseMusicFolderRequested)) { _ in showFileImporter = true }
            .onReceive(NotificationCenter.default.publisher(for: .RescanLibraryRequested)) { _ in rescanLibrary() }
            .onReceive(NotificationCenter.default.publisher(for: .PlayHistoryDidClear), perform: handlePlayHistoryCleared)
            .preferredColorScheme(appAppearance == "light" ? .light : appAppearance == "dark" ? .dark : nil)
    }

    @ViewBuilder
    private func applyFocusedSceneValues<V: View>(_ content: V) -> some View {
        content
            .focusedSceneValue(\.deletePlaylistAction, deletePlaylistAction())
            .focusedSceneValue(\.newPlaylistAction, newPlaylistAction)
            .focusedSceneValue(\.newSmartPlaylistAction, newSmartPlaylistAction)
            .focusedSceneValue(\.importMusicAction, importMusicAction)
            .focusedSceneValue(\.importPlaylistAction, importPlaylistAction)
            .focusedSceneValue(\.exportPlaylistAction, exportPlaylistMenuAction())
            .focusedSceneValue(\.focusSearchFieldAction, focusSearchFieldAction)
            .focusedSceneValue(\.showListViewAction, showListViewAction)
            .focusedSceneValue(\.showAlbumGridAction, showAlbumGridAction)
            .focusedSceneValue(\.showCoverFlowAction, showCoverFlowAction)
            .focusedSceneValue(\.toggleUpNextAction, toggleUpNextMenuAction)
            .focusedSceneValue(\.showUpNextValue, showUpNext)
            .focusedSceneValue(\.toggleVisualizerAction, toggleVisualizerMenuAction)
            .focusedSceneValue(\.showVisualizerValue, showVisualizer)
            .focusedSceneValue(\.toggleLyricsAction, toggleLyricsMenuAction)
            .focusedSceneValue(\.showLyricsValue, showLyrics)
            .focusedSceneValue(\.toggleMiniPlayerAction, toggleMiniPlayer)
            .focusedSceneValue(\.togglePlayPauseAction, togglePlayPauseAction)
            .focusedSceneValue(\.isPlayingValue, engine.player?.rate != 0)
            .focusedSceneValue(\.playNextAction, engine.playNext)
            .focusedSceneValue(\.playPreviousAction, engine.playPrevious)
            .focusedSceneValue(\.increaseVolumeAction, increaseVolumeAction)
            .focusedSceneValue(\.decreaseVolumeAction, decreaseVolumeAction)
            .focusedSceneValue(\.toggleMuteAction, toggleMuteAction)
            .focusedSceneValue(\.isMutedValue, engine.volume == 0)
            .focusedSceneValue(\.toggleShuffleAction, toggleShuffleAction)
            .focusedSceneValue(\.isShuffleValue, engine.isShuffleEnabled)
            .focusedSceneValue(\.cycleRepeatModeAction, cycleRepeatModeAction)
            .focusedSceneValue(\.isRepeatAllValue, engine.isRepeatEnabled)
            .focusedSceneValue(\.isRepeatOneValue, engine.isRepeatOne)
            .focusedSceneValue(\.showKeyboardShortcutsAction, showKeyboardShortcutsAction)
            .focusedSceneValue(\.showSongInfoAction, showSongInfoMenuAction())
    }

    private func newPlaylistAction() {
        showNewPlaylistSheet = true
    }

    private func newSmartPlaylistAction() {
        showNewSmartPlaylistSheet = true
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

    private func toggleArtworkPaneAction() {
        withAnimation { showArtworkPane.toggle() }
    }

    private func toggleUpNextMenuAction() {
        withAnimation {
            showUpNext.toggle()
            if showUpNext {
                engine.updateUpcomingSongs()
            }
        }
    }

    private func toggleVisualizerMenuAction() {
        showVisualizer.toggle()
    }

    private func toggleLyricsMenuAction() {
        withAnimation {
            showLyrics.toggle()
            if showLyrics, let song = engine.selectedSong {
                loadLyrics(for: song)
            }
        }
    }

    private func togglePlayPauseAction() {
        engine.togglePlayPause()
    }

    private func increaseVolumeAction() {
        engine.volume = min(1.0, engine.volume + 0.1)
    }

    private func decreaseVolumeAction() {
        engine.volume = max(0.0, engine.volume - 0.1)
    }

    private func toggleMuteAction() {
        if engine.volume > 0 {
            volumeBeforeMute = engine.volume
            engine.volume = 0
        } else {
            engine.volume = volumeBeforeMute > 0 ? volumeBeforeMute : 0.5
        }
    }

    private func toggleShuffleAction() {
        engine.isShuffleEnabled.toggle()
    }

    private func cycleRepeatModeAction() {
        if !engine.isRepeatEnabled && !engine.isRepeatOne {
            engine.isRepeatEnabled = true
            engine.isRepeatOne = false
        } else if engine.isRepeatEnabled && !engine.isRepeatOne {
            engine.isRepeatEnabled = false
            engine.isRepeatOne = true
        } else {
            engine.isRepeatEnabled = false
            engine.isRepeatOne = false
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

    // Registers exactly once, ever, since it runs from PlayerEngine's
    // private init() rather than from this View's onAppear — see
    // PlayerEngine.swift for why that distinction matters.
    private static var lifecycleObserversConfigured = false

    private func handleContentViewAppear() {
        print("Running loadSongsOnce at launch")
        loadSongsOnce()

        // Refresh these every time the view appears (window reopened, mini
        // player closed, etc.) so the engine always asks the currently
        // visible UI for playback context / side effects, without ever
        // holding on to a stale View instance itself.
        engine.contextProvider = { [self] song in playbackContext(for: song) }
        engine.onSongChanged = { [self] song in
            incrementPlayCount(for: song)
            if let index = songs.firstIndex(where: { $0.id == song.id }) {
                songs[index].playCount = getPlayCount(for: song)
            }
            refreshPlaybackSystemPlaylists()
            if showLyrics {
                loadLyrics(for: song)
            }
        }

        if !Self.lifecycleObserversConfigured {
            Self.lifecycleObserversConfigured = true

            // Stop security-scoped access cleanly when the app quits
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main,
                using: handleWillTerminate
            )
        }
    }

    private func handleContentViewDisappear() {
        // Intentionally a no-op for playback bookkeeping: the time observer
        // and end-of-song observer must keep running even while the window
        // is hidden/closed (mini player, traffic-light close) so playback
        // position keeps updating and the next song still starts
        // automatically when the current one ends. They are only ever torn
        // down in stopCurrentPlayback(), when we actually swap to a new
        // AVPlayer/AVPlayerItem.
    }

    private func handleWillTerminate(_ notification: Notification) {
        releaseFolderAccess()
    }

    private var isPlayingBinding: Binding<Bool> {
        Binding(
            get: { engine.player?.rate != 0 },
            set: { shouldPlay in
                if shouldPlay {
                    engine.play()
                } else {
                    engine.pause()
                }
            }
        )
    }

    private func toggleLyricsButtonAction() {
        withAnimation {
            showLyrics.toggle()
            if showLyrics, let song = engine.selectedSong {
                loadLyrics(for: song)
            }
        }
    }

    private func toggleUpNextButtonAction() {
        withAnimation {
            showUpNext.toggle()
            if showUpNext {
                engine.updateUpcomingSongs()
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
        panel.prompt = NSLocalizedString("panel.choose", comment: "")
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

    private func showSongInfoMenuAction() -> (() -> Void)? {
        guard engine.selectedSong != nil else { return nil }
        return { songForInfo = engine.selectedSong }
    }

    // Propagates an edited song's metadata to every place a copy of it is held:
    // the library, every user playlist, and the currently selected/playing song.
    private func applyMetadataUpdate(_ updated: Song) {
        if let index = songs.firstIndex(where: { $0.id == updated.id }) {
            songs[index] = updated
        }
        for playlistIndex in playlistManager.userPlaylists.indices {
            if let songIndex = playlistManager.userPlaylists[playlistIndex].songs.firstIndex(where: { $0.id == updated.id }) {
                playlistManager.userPlaylists[playlistIndex].songs[songIndex] = updated
            }
        }
        if engine.selectedSong?.id == updated.id {
            engine.selectedSong = updated
        }
        generateSystemPlaylists()
        saveUserPlaylists()
    }

    private func handleAddToUpNextNotification(_ output: Notification) {
        if let song = output.object as? Song {
            engine.addSongsNext([song])
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
                                applyLoadedSongs(loaded)
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

    // Re-reads the current music folder (used by Settings → "Rescan Library Now").
    private func rescanLibrary() {
        guard let folderURL = musicFolderAccess else { return }
        Task {
            let loaded = await loadSongs(from: folderURL)
            await MainActor.run {
                applyLoadedSongs(loaded)
            }
        }
    }

    // Recomputes play counts and the smart playlists after Settings clears play history.
    private func handlePlayHistoryCleared(_ output: Notification) {
        refreshSongPlayCounts()
        generateSystemPlaylists()
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
                        applyLoadedSongs(loaded)
                        engine.restoreLastSong(from: loaded)
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

    // Thin wrapper: preserves the "don't try to play without folder access"
    // guard, then hands off to PlayerEngine (the single source of truth for
    // everything else — queues, shuffle/repeat, the AVPlayer itself).
    private func playSong(_ song: Song) {
        guard musicFolderAccess != nil else {
            print("No folder access retained.")
            return
        }
        engine.playSong(song)
    }

    // Installs a freshly scanned library: counts, smart lists and the Stable Volume index all depend on it.
    private func applyLoadedSongs(_ loaded: [Song]) {
        songs = loaded
        refreshSongPlayCounts()
        generateSystemPlaylists()
        StableVolumeIndex.shared.sync(with: loaded.map(\.url))
        pruneUnusedArtwork()
    }

    // Deletes cached artwork that neither the library nor any playlist refers to any more.
    private func pruneUnusedArtwork() {
        // An empty library usually means the music folder was unavailable, not that every song was
        // removed, so don't delete anything on that basis.
        guard !songs.isEmpty else { return }
        var referenced = Set(songs.compactMap(\.artworkKey))
        for playlist in playlistManager.userPlaylists {
            referenced.formUnion(playlist.songs.compactMap(\.artworkKey))
        }
        Task.detached(priority: .utility) {
            ArtworkStore.shared.prune(keeping: referenced)
        }
    }

    // Copies every song's saved play count onto the library. The counts are read once and the
    // library is assigned once, instead of reading the counts table and mutating the array per song.
    private func refreshSongPlayCounts() {
        let counts = getAllPlayCounts()
        var updated = songs
        for index in updated.indices {
            updated[index].playCount = counts[updated[index].id] ?? 0
        }
        songs = updated
    }

    // The library without repeated entries, in library order.
    private func uniqueLibrarySongs() -> [Song] {
        var seen = Set<UUID>()
        return songs.filter { seen.insert($0.id).inserted }
    }

    private func generateSystemPlaylists() {
        let uniqueSongs = uniqueLibrarySongs()
        systemPlaylists = [
            generateRecentlyPlayedPlaylist(from: uniqueSongs),
            generateTopPlayedPlaylist(from: uniqueSongs),
            generate90sMusicPlaylist(from: uniqueSongs),
            generateClassicalMusicPlaylist(from: uniqueSongs),
            generateRecentlyAddedPlaylist(from: uniqueSongs)
        ]
    }

    // Playing a song only changes "Recently Played" and "Top 25", so rebuild just those two instead
    // of re-filtering and re-sorting the whole library for every other smart list on each new song.
    private func refreshPlaybackSystemPlaylists() {
        guard systemPlaylists.count == 5 else {
            generateSystemPlaylists()
            return
        }
        let uniqueSongs = uniqueLibrarySongs()
        systemPlaylists[0] = generateRecentlyPlayedPlaylist(from: uniqueSongs)
        systemPlaylists[1] = generateTopPlayedPlaylist(from: uniqueSongs)
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

    // Uses the creation date captured during the library scan, so no file has to be stat'ed here.
    private func generateRecentlyAddedPlaylist(from songs: [Song]) -> Playlist {
        let newest = songs
            .compactMap { song in song.dateAdded.map { (song: song, date: $0) } }
            .sorted { $0.date > $1.date }
            .prefix(25)
            .map { $0.song }
        return Playlist(name: "Recently Added", songs: newest, isSystem: true)
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
                            if self.lyricsText == NSLocalizedString("lyrics.tryingOnline", comment: "") {
                                if let fetched = await self.fetchLyricsFromLRCLib(for: song) {
                                    await MainActor.run { self.lyricsText = fetched }
                                } else {
                                    await MainActor.run {
                                        if self.lyricsText.isEmpty || self.lyricsText == NSLocalizedString("lyrics.tryingOnline", comment: "") {
                                            self.lyricsText = NSLocalizedString("lyrics.noOnline", comment: "")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                print("Extraction failed: \(error)")
                await MainActor.run { self.lyricsText = NSLocalizedString("lyrics.errorMetadata", comment: "") }
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
                self.lyricsText = NSLocalizedString("lyrics.lrcUnreadable", comment: "")
            }
        } else {
            self.lyricsText = NSLocalizedString("lyrics.tryingOnline", comment: "")
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
            if self.lyricsText.isEmpty || self.lyricsText == NSLocalizedString("lyrics.tryingOnline", comment: "") {
                self.lyricsText = NSLocalizedString("lyrics.noOnline", comment: "")
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
        isMiniPlayerActive = true

        // Hide main window
        if let mainWindow = NSApp.mainWindow {
            mainWindow.orderOut(nil)
        }

        // Create and show mini player window
        let miniPlayerView = MiniPlayerHost(engine: engine, onClose: closeMiniPlayer)

        let hostingController = NSHostingController(rootView: miniPlayerView.environmentObject(appearanceManager))

        // The window is vertically resizable: dragging it taller than the default bar reveals Up Next.
        // The hosting controller derives the window's min/max size from the SwiftUI view,
        // so the content always lays out to match the window as it is resized.
        hostingController.sizingOptions = [.minSize, .maxSize]

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: MiniPlayerView.width, height: MiniPlayerView.barHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: MiniPlayerView.width, height: MiniPlayerView.barHeight))
        window.contentMinSize = NSSize(width: MiniPlayerView.width, height: MiniPlayerView.barHeight)
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
              let playlist = playlist(withID: playlistID) else {
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
    
    // Parse M3U content into entries with optional EXTINF metadata
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
            Text("queue.nowPlaying")
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
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
                Divider()
            }

            if !upcomingSongs.isEmpty {
                Text("queue.nextUp")
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
                        .stroke(.tint, lineWidth: 2)
                        .opacity(externalDropHovering ? 1 : 0)
                        .padding(4)
                )

            } else if isPlaying {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.tint.opacity(externalDropHovering ? 1 : 0.35), lineWidth: 1.5)
                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("queue.noUpcoming")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("queue.dragHere")
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
                    Text("queue.noSong")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AquaSidebarBackground())
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
                    .fill(.tint)
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
            if let img = song.artworkThumbnail(maxPixelSize: Int(size * 3)) {
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
                if let img = song.artworkThumbnail(maxPixelSize: 108) {
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
                    ? AnyShapeStyle(.tint.opacity(0.12))
                    : AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 1 : 0.7)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDragging ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(Color.clear), lineWidth: 1.5)
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
                .padding(.top, 16)

            if let song = currentSong {
                HStack(spacing: 12) {
                    if let image = song.artworkThumbnail(maxPixelSize: 150) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AquaSidebarBackground())
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
