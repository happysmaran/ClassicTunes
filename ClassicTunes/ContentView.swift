import SwiftUI
import AVKit

extension Color {
    static let itunesSidebar = Color(NSColor(calibratedWhite: 0.9, alpha: 1.0))
    static let itunesWindowBG = Color(NSColor(calibratedWhite: 0.2, alpha: 1.0))
    static let itunesHeaderBG = Color(red: 0.3, green: 0.3, blue: 0.3)
    static let itunesSelected = Color(red: 0.32, green: 0.44, blue: 0.76)
}

struct Song: Identifiable, Codable, Hashable {
    let id: UUID
    let url: URL
    let title: String
    let artist: String
    let album: String
    let year: String
    let genre: String
    var playCount: Int = 0 // Added play count
    
    init(id: UUID = UUID(), url: URL, title: String, artist: String, album: String, year: String, genre: String, playCount: Int = 0) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.genre = genre
        self.playCount = playCount
    }
}

struct Playlist: Identifiable, Codable {
    let id: UUID
    var name: String
    var songs: [Song]
    var isSystem: Bool = false // Indicates if it's a system playlist
    
    init(id: UUID = UUID(), name: String, songs: [Song], isSystem: Bool = false) {
        self.id = id
        self.name = name
        self.songs = songs
        self.isSystem = isSystem
    }
}

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
    @State private var playlists: [Playlist] = []
    @State private var selectedPlaylistID: UUID?
    @State private var showNewPlaylistSheet = false

    var displayedSongs: [Song] {
        if let playlistID = selectedPlaylistID,
           let playlist = playlists.first(where: { $0.id == playlistID }) {
            return playlist.songs
        }
        return songs
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
                Sidebar(
                    playlists: $playlists,
                    selectedPlaylistID: $selectedPlaylistID,
                    showNewPlaylistSheet: $showNewPlaylistSheet
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
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            print("Running loadSongsOnce at launch")
            loadSongsOnce()
            playlists = loadPlaylistsFromUserDefaults()
            initializeDefaultPlaylists()
        }
        .sheet(isPresented: $showNewPlaylistSheet) {
            NewPlaylistSheet(playlists: $playlists)
        }
    }

    func loadSongsOnce() {
        guard !musicFolderBookmarkData.isEmpty else { return }

        do {
            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: musicFolderBookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)

            if resolvedURL.startAccessingSecurityScopedResource() {
                musicFolderAccess = resolvedURL
                songs = loadSongs(from: resolvedURL)
                print("Successfully loaded songs from bookmark.")
            } else {
                print("Failed to access security scoped resource from bookmark.")
            }
        } catch {
            print("Error resolving bookmark: \(error)")
        }
    }

    func playSong(_ song: Song) {
        guard musicFolderAccess != nil else {
            print("No folder access retained.")
            return
        }

        // Set currentAlbumSongs depending on view mode: album view = album songs, else all songs
        currentAlbumSongs = isAlbumView
            ? songs.filter { $0.album == song.album }
            : songs

        // Stop previous playback
        player?.pause()
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        playerItem = nil
        player = nil

        // Setup new playback
        let item = AVPlayerItem(url: song.url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = Float(volume)
        newPlayer.play()
        player = newPlayer
        playerItem = item
        selectedSong = song
        playbackDuration = item.asset.duration.seconds
        playbackPosition = 0.0

        let interval = CMTime(seconds: 1.0, preferredTimescale: 1)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            if !isSeeking {
                playbackPosition = seconds / max(playbackDuration, 0.1)
            }
        }

        // Autoplay next track at end
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            playNext()
        }

        // Update play count in playlists
        updatePlaylistsSong(song)
    }
    
    func playNext() {
        guard let current = selectedSong else { return }

        if isShuffleEnabled {
            let pool = currentAlbumSongs.filter { $0.id != current.id }
            if let randomSong = pool.randomElement() {
                playSong(randomSong)
            }
            return
        }

        guard let currentIndex = currentAlbumSongs.firstIndex(where: { $0.id == current.id }) else { return }

        let nextIndex = currentIndex + 1
        if nextIndex < currentAlbumSongs.count {
            playSong(currentAlbumSongs[nextIndex])
        } else if isRepeatEnabled {
            playSong(currentAlbumSongs.first!)
        }
    }

    func playPrevious() {
        guard let current = selectedSong else { return }

        if isShuffleEnabled {
            let pool = currentAlbumSongs.filter { $0.id != current.id }
            if let randomSong = pool.randomElement() {
                playSong(randomSong)
            }
            return
        }

        guard let currentIndex = currentAlbumSongs.firstIndex(where: { $0.id == current.id }) else { return }

        let previousIndex = currentIndex - 1
        if previousIndex >= 0 {
            playSong(currentAlbumSongs[previousIndex])
        } else if isRepeatEnabled {
            playSong(currentAlbumSongs.last!)
        }
    }
    
    func handleSeek(_ value: Double) {
        if value == -1 {
            player?.volume = Float(volume)
        } else {
            let seconds = value * playbackDuration
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            player?.seek(to: time)
        }
    }

    func initializeDefaultPlaylists() {
        if playlists.isEmpty {
            playlists = [
                Playlist(name: "Recently Played", songs: [], isSystem: true),
                Playlist(name: "Top 25 Most Played", songs: [], isSystem: true),
                Playlist(name: "My Top Rated", songs: [], isSystem: true)
            ]
            savePlaylistsToUserDefaults(playlists)
        }
    }

    func updatePlaylistsSong(_ song: Song) {
        if let index = playlists.firstIndex(where: { $0.name == "Recently Played" }) {
            var updatedSongs = playlists[index].songs
            if !updatedSongs.contains(where: { $0.id == song.id }) {
                updatedSongs.insert(song, at: 0)
                if updatedSongs.count > 25 {
                    updatedSongs.removeLast()
                }
                playlists[index].songs = updatedSongs
            }
        }

        if let index = playlists.firstIndex(where: { $0.name == "Top 25 Most Played" }) {
            var updatedSongs = Array(Set(playlists[index].songs + [song]))
            updatedSongs.sort { ($0.playCount, $0.title) > ($1.playCount, $1.title) }
            if updatedSongs.count > 25 {
                updatedSongs = Array(updatedSongs.prefix(25))
            }
            playlists[index].songs = updatedSongs
        }

        savePlaylistsToUserDefaults(playlists)
    }
}

struct Sidebar: View {
    @Binding var playlists: [Playlist]
    @Binding var selectedPlaylistID: UUID?
    @Binding var showNewPlaylistSheet: Bool

    var body: some View {
        List {
            Section("LIBRARY") {
                Label("Music", systemImage: "music.note")
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
                                if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                                    playlists.remove(at: index)
                                    savePlaylistsToUserDefaults(playlists)
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

struct SongListView: View {
    var isAlbumView: Bool
    var songs: [Song]
    var onSongSelect: (Song) -> Void
    @Binding var selectedSong: Song?
    var onAlbumSelect: (String) -> Void = { _ in }
    var playlistSongs: [Song]?
    @State private var sortBy = "title"

    var sortedSongs: [Song] {
        let songsToSort = playlistSongs ?? songs
        switch sortBy {
        case "title":
            return songsToSort.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "artist":
            return songsToSort.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case "album":
            return songsToSort.sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        case "year":
            return songsToSort.sorted { $0.year.localizedCaseInsensitiveCompare($1.year) == .orderedAscending }
        case "genre":
            return songsToSort.sorted { $0.genre.localizedCaseInsensitiveCompare($1.genre) == .orderedAscending }
        default:
            return songsToSort
        }
    }

    var displayedSongs: [Song] {
        playlistSongs ?? songs
    }

    var body: some View {
        VStack(spacing: 0) {
            if isAlbumView {
                AlbumGridView(
                    songs: displayedSongs,
                    selectedAlbum: selectedSong?.album,
                    onAlbumSelect: onAlbumSelect
                )
            } else {
                let displayedSongs = sortedSongs

                List {
                    // Column headers
                    HStack {
                        Text("Title").fontWeight(.bold).frame(maxWidth: .infinity, alignment: .leading)
                            .onTapGesture { sortBy = "title" }
                        Text("Artist").fontWeight(.bold).frame(maxWidth: .infinity, alignment: .leading)
                            .onTapGesture { sortBy = "artist" }
                        Text("Album").fontWeight(.bold).frame(maxWidth: .infinity, alignment: .leading)
                            .onTapGesture { sortBy = "album" }
                        Text("Year").fontWeight(.bold).frame(width: 50, alignment: .leading)
                            .onTapGesture { sortBy = "year" }
                        Text("Genre").fontWeight(.bold).frame(width: 80, alignment: .leading)
                            .onTapGesture { sortBy = "genre" }
                    }

                    // Song rows
                    ForEach(displayedSongs) { song in
                        HStack {
                            Text(song.title).frame(maxWidth: .infinity, alignment: .leading)
                            Text(song.artist).frame(maxWidth: .infinity, alignment: .leading)
                            Text(song.album).frame(maxWidth: .infinity, alignment: .leading)
                            Text(song.year).frame(width: 50, alignment: .leading)
                            Text(song.genre).frame(width: 80, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .background(
                            selectedSong?.id == song.id
                            ? Color.accentColor.opacity(0.3)
                            : Color.clear
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedSong = song
                            onSongSelect(song)
                        }
                    }
                }
            }

            Divider()
        }
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color(NSColor(calibratedWhite: 0.96, alpha: 1.0)), Color.white]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .foregroundColor(.black)
    }
}

struct AlbumGridView: View {
    @Environment(\.colorScheme) var colorScheme
    var songs: [Song]
    var selectedAlbum: String?
    var onAlbumSelect: (String) -> Void
    @State private var coverSize: CGFloat = 120

    let columns = [
        GridItem(.adaptive(minimum: 140), spacing: 20)
    ]

    var body: some View {
        let groupedAlbums = Dictionary(grouping: songs) { $0.album }

        // Capsule-style slider for album cover size
        HStack {
            Spacer()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 4)

                    Capsule()
                        .fill(Color(NSColor(calibratedWhite: 0.15, alpha: 1.0)))
                        .frame(width: CGFloat((coverSize - 60) / 140) * geometry.size.width, height: 4)
                }
                .frame(height: 10)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let percent = min(max(0, value.location.x / geometry.size.width), 1)
                        coverSize = 60 + percent * 140
                    }
                )
            }
            .frame(width: 160, height: 10)
        }
        .padding(.horizontal)
        .padding(.top, 8)

        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(groupedAlbums.keys.sorted(), id: \.self) { album in
                    VStack {
                        // Album artwork or fallback
                        if let artwork = songs.first(where: { $0.album == album })?.url,
                           let image = getArtwork(from: artwork) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: coverSize, height: coverSize)
                                .cornerRadius(8)
                        } else {
                            ZStack {
                                Rectangle()
                                    .fill(Color.white.opacity(0.05))
                                    .frame(width: coverSize, height: coverSize)
                                    .cornerRadius(8)
                                Image(systemName: "music.note")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: coverSize * 0.5, height: coverSize * 0.5)
                                    .foregroundColor(.gray)
                            }
                        }

                        Text(album)
                            .font(.caption)
                            .frame(maxWidth: coverSize)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selectedAlbum == album ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                    .onTapGesture {
                        onAlbumSelect(album)
                    }
                }
            }
            .padding()
        }
        .background(Color.black)
    }
}

struct TopToolbarView: View {
    @Binding var isAlbumView: Bool
    @Binding var showFileImporter: Bool
    @Binding var selectedSong: Song?
    @Binding var isPlaying: Bool
    var playPrevious: () -> Void
    var playNext: () -> Void
    @Binding var volume: Double
    @Binding var playbackPosition: Double
    @Binding var playbackDuration: Double
    var onSeek: (Double) -> Void
    @Binding var isSeeking: Bool
    @Binding var isShuffleEnabled: Bool
    @Binding var isRepeatEnabled: Bool
    @Binding var isStopped: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Playback controls
            HStack(spacing: 8) {
                Button(action: playPrevious) {
                    Image(systemName: "backward.fill")
                        .padding(8)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [.white.opacity(0.7), .gray.opacity(0.4)]),
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                }
                .buttonStyle(.plain)

                Button(action: {
                    isPlaying = !isPlaying
                    if isPlaying {
                        isStopped = false
                    }
                }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .padding(8)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [.white.opacity(0.7), .gray.opacity(0.4)]),
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                }
                .buttonStyle(.plain)

                Button(action: {
                    isPlaying = false
                    isStopped = true
                    selectedSong = nil
                }) {
                    Image(systemName: "stop.fill")
                        .padding(8)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [.white.opacity(0.7), .gray.opacity(0.4)]),
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                }
                .buttonStyle(.plain)

                Button(action: playNext) {
                    Image(systemName: "forward.fill")
                        .padding(8)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [.white.opacity(0.7), .gray.opacity(0.4)]),
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                }
                .buttonStyle(.plain)
            }

            // Volume
            Slider(value: Binding(
                get: { volume },
                set: { volume = $0 }
            ), in: 0...1)
                .frame(width: 100)
                .onChange(of: volume) { newVolume in
                    onSeek(-1) // Special value to update volume
                }

            // Center: Apple logo or song info in glossy capsule
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.88, green: 0.94, blue: 0.88),
                            Color(red: 0.76, green: 0.85, blue: 0.76)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(NSColor(calibratedWhite: 0.6, alpha: 1.0)), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.15), radius: 1, x: 0, y: 1)
                    .frame(height: 56)

                VStack(spacing: 2) {
                    if let song = selectedSong, isPlaying || !isStopped {
                        Text(song.title)
                            .font(.subheadline)
                            .foregroundColor(.black)
                            .shadow(color: .white.opacity(0.8), radius: 0.5, x: 0, y: 1)

                        AnimatedLabel(texts: [song.artist, song.album])
                            .font(.caption2)
                            .foregroundColor(.black)
                            .shadow(color: .white.opacity(0.8), radius: 0.5, x: 0, y: 1)

                        Slider(
                            value: Binding(
                                get: { playbackPosition },
                                set: { newValue in
                                    isSeeking = true
                                    playbackPosition = newValue
                                }
                            ),
                            in: 0...1,
                            onEditingChanged: { editing in
                                if !editing {
                                    onSeek(playbackPosition)
                                    isSeeking = false
                                }
                            }
                        )
                        .frame(width: 280)
                        .tint(Color.gray)
                        .frame(height: 4)
                        .padding(.top, 4)
                    } else {
                        Image(systemName: "applelogo")
                            .font(.title)
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.vertical, 4)

            // View toggle buttons
            HStack(spacing: 6) {
                Button(action: { isAlbumView = false }) {
                    Image(systemName: "list.bullet")
                        .foregroundColor(!isAlbumView ? .accentColor : .gray)
                }
                .buttonStyle(.borderless)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.5))
                )

                Button(action: { isAlbumView = true }) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundColor(isAlbumView ? .accentColor : .gray)
                }
                .buttonStyle(.borderless)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.5))
                )

                Button(action: { isShuffleEnabled.toggle() }) {
                    Image(systemName: "shuffle")
                        .foregroundColor(isShuffleEnabled ? .accentColor : .gray)
                }
                .buttonStyle(.borderless)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.5))
                )

                Button(action: { isRepeatEnabled.toggle() }) {
                    Image(systemName: "repeat")
                        .foregroundColor(isRepeatEnabled ? .accentColor : .gray)
                }
                .buttonStyle(.borderless)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.5))
                )
            }

            TextField("Search", text: .constant(""))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)

            Button("Import Music") {
                showFileImporter = true
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.white,
                    Color(NSColor(calibratedWhite: 0.85, alpha: 1.0))
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
        .foregroundColor(.black)
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

func loadSongs(from folderURL: URL) -> [Song] {
    let allowedExtensions = ["mp3", "m4a", "aac", "wav", "flac"]
    let fileManager = FileManager.default
    var loadedSongs: [Song] = []

    guard let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: nil) else {
        print("Could not create enumerator")
        return []
    }

    for case let fileURL as URL in enumerator {
        guard allowedExtensions.contains(fileURL.pathExtension.lowercased()) else {
            continue
        }

        let asset = AVURLAsset(url: fileURL)

        var title = fileURL.deletingPathExtension().lastPathComponent
        var artist = "Unknown Artist"
        var album = "Unknown Album"
        var year = "—"
        var genre = "—"

        for item in asset.commonMetadata {
            switch item.commonKey?.rawValue {
            case "title":
                title = item.value as? String ?? title
            case "artist":
                artist = item.value as? String ?? artist
            case "albumName":
                album = item.value as? String ?? album
            case "year":
                year = item.value as? String ?? year
            case "type":
                genre = item.value as? String ?? genre
            default:
                break
            }
        }

        let song = Song(url: fileURL, title: title, artist: artist, album: album, year: year, genre: genre)
        loadedSongs.append(song)
    }

    return loadedSongs
}

// Helper to extract artwork from audio file URL
func getArtwork(from url: URL) -> NSImage? {
    let asset = AVURLAsset(url: url)
    let metadata = asset.commonMetadata

    for item in metadata {
        if item.commonKey?.rawValue == "artwork",
           let data = item.value as? Data,
           let image = NSImage(data: data) {
            return image
        }
    }

    return nil
}

func loadPlaylistsFromUserDefaults() -> [Playlist] {
    guard let data = UserDefaults.standard.data(forKey: "playlists") else {
        return []
    }
    let decoder = JSONDecoder()
    do {
        let playlists = try decoder.decode([Playlist].self, from: data)
        return playlists
    } catch {
        print("Error decoding playlists: \(error)")
        return []
    }
}

func savePlaylistsToUserDefaults(_ playlists: [Playlist]) {
    let encoder = JSONEncoder()
    do {
        let data = try encoder.encode(playlists)
        UserDefaults.standard.set(data, forKey: "playlists")
    } catch {
        print("Error encoding playlists: \(error)")
    }
}

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

