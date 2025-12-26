import SwiftUI
import ImageIO

struct CoverFlowView: View {
    let albums: [AlbumInfo]
    @Binding var selectedAlbum: String?
    @Binding var isCoverFlowActive: Bool
    var onAlbumSelect: (String) -> Void
    var songs: [Song] = []
    
    // Added bindings for playback management because uhh thing is garabage
    @Binding var selectedSong: Song?
    @Binding var currentPlaybackSongs: [Song]
    @Binding var shuffleQueue: [Song]
    @Binding var isShuffleEnabled: Bool
    @Binding var isRepeatOne: Bool
    @Binding var isRepeatEnabled: Bool

    @State private var currentIndex: Int = 0
    @State private var committedIndex: Int = 0 // Index committed after interaction ends
    @State private var sliderValue: Double = 0.0
    @State private var sortBy = "title"
    @State private var showAllSongs = true // New state to toggle between all songs and album songs
    @State private var isInteracting = false // Track interaction to defer playback and commit index

    // Get songs for the committed album (prevents list churn while sliding)
    private var albumSongs: [Song] {
        guard !albums.isEmpty && committedIndex < albums.count else { return [] }
        let currentAlbum = albums[committedIndex]
        return songs.filter { $0.album == currentAlbum.name }
    }
    
    // All songs or album songs based on toggle
    private var displayedSongs: [Song] {
        showAllSongs ? songs : albumSongs
    }

    private var sortedSongs: [Song] {
        switch sortBy {
        case "title":
            return displayedSongs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "artist":
            return displayedSongs.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case "album":
            return displayedSongs.sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        case "genre":
            return displayedSongs.sorted { $0.genre.localizedCaseInsensitiveCompare($1.genre) == .orderedAscending }
        default:
            return displayedSongs
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Reduced height for CoverFlow area to make space for the list
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.white,
                        Color(red: 0.9, green: 0.9, blue: 0.9),
                        Color.white
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )

                GeometryReader { geometry in
                    let size = geometry.size
                    let coverWidth = size.width * 0.18
                    let centerX = size.width / 2
                    let coverMargin = coverWidth / 2 + size.width * 0.04
                    let leftEdge = coverMargin
                    let rightEdge = size.width - coverMargin

                    let leftCount = currentIndex
                    let rightCount = albums.count - currentIndex - 1

                    ZStack {
                        ForEach(Array(albums.enumerated()), id: \.offset) { index, album in
                            let isCenter = index == currentIndex
                            let frameWidth = isCenter ? coverWidth * 1.2 : coverWidth

                            let x: CGFloat = {
                                if index < currentIndex {
                                    // Left stack
                                    let distanceFromCenter = currentIndex - index
                                    if leftCount > 0 {
                                        let t = leftCount > 1 ? CGFloat(leftCount - distanceFromCenter) / CGFloat(leftCount - 1) : 0
                                        return leftEdge * (1 - t) + (centerX - coverWidth/2) * t
                                    } else {
                                        return centerX - coverWidth/2
                                    }
                                } else if isCenter {
                                    return centerX
                                } else {
                                    // Right stack
                                    let distanceFromCenter = index - currentIndex
                                    if rightCount > 0 {
                                        let t = rightCount > 1 ? CGFloat(distanceFromCenter - 1) / CGFloat(rightCount - 1) : 0
                                        return (centerX + coverWidth/2) * (1 - t) + rightEdge * t
                                    } else {
                                        return centerX + coverWidth/2
                                    }
                                }
                            }()

                            CoverFlowItemView(
                                album: album,
                                index: index,
                                currentIndex: currentIndex,
                                geometry: geometry,
                                isInteracting: isInteracting
                            )
                            .frame(width: frameWidth, height: frameWidth)
                            .aspectRatio(1, contentMode: .fit)
                            .position(x: x, y: size.height / 2)
                            .zIndex(Double(albums.count) - abs(Double(index - currentIndex)))
                            .onTapGesture {
                                isInteracting = true
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    currentIndex = index
                                    sliderValue = Double(index)
                                }
                                // Commit the index and play slightly after the animation
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    committedIndex = index
                                    selectAndPlay(album: album)
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    isInteracting = false
                                }
                            }
                            .focusable(false)
                            .buttonStyle(PlainButtonStyle())
                            .accentColor(.clear)
                            .border(Color.clear, width: 0)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 320) // Reduced height from 480 to 320
            .contentShape(Rectangle())

            if !albums.isEmpty && currentIndex < albums.count {
                VStack(alignment: .center, spacing: 8) {
                    Text(albums[currentIndex].name)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                    Text(albums[currentIndex].artist)
                        .font(.title3)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.7))
            }

            if albums.count > 1 {
                HStack {
                    Text("1")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(width: 24, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { sliderValue },
                            set: { newValue in
                                sliderValue = newValue
                                let intValue = Int(round(newValue))
                                if currentIndex != intValue {
                                    currentIndex = intValue
                                }
                            }
                        ),
                        in: 0...Double(albums.count - 1),
                        step: 1,
                        onEditingChanged: { isEditing in
                            isInteracting = isEditing
                            if !isEditing {
                                // Commit the index after the drag ends
                                committedIndex = currentIndex
                                // Defer playback slightly to allow the animation to finish
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    playCurrentAlbum()
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    isInteracting = false
                                }
                            }
                        }
                    )
                    .accentColor(Color(NSColor.systemBlue))
                    .frame(height: 4)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 0)
                    Text("\(albums.count)")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(width: 24, alignment: .trailing)
                }
                .padding(.horizontal, 40)
                .background(Color.clear)
            }
            
            // iTunes-style list view copied from SongListView.swift
            VStack(spacing: 0) {
                // Column headers with toggle button
                HStack {
                    headerButton("Title", sort: "title")
                    headerButton("Artist", sort: "artist")
                    headerButton("Album", sort: "album")
                    headerButton("Genre", sort: "genre", width: 100)
                    
                    Spacer()
                    
                    // Better positioned toggle button
                    Button(action: {
                        showAllSongs.toggle()
                    }) {
                        HStack {
                            Image(systemName: showAllSongs ? "music.note.list" : "square.on.square")
                            Text(showAllSongs ? "All Songs" : "Album Songs")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.1))
                        )
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 12)
                .background(Color.gray.opacity(0.2))
                
                // Song list
                List {
                    ForEach(sortedSongs) { song in
                        HStack {
                            Text(song.title).frame(maxWidth: .infinity, alignment: .leading)
                            Text(song.artist).frame(maxWidth: .infinity, alignment: .leading)
                            Text(song.album).frame(maxWidth: .infinity, alignment: .leading)
                            Text(song.genre).frame(width: 100, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .background(
                            selectedSong?.id == song.id
                            ? Color.blue.opacity(0.3)
                            : Color.clear
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Play the selected song
                            playSong(song)
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .listStyle(.plain)
            }
            .frame(maxHeight: 300) // Fixed height for the list section
            
            Spacer()
        }
        .background(Color.white)
        .clipShape(Rectangle())
        .onChange(of: committedIndex) { newValue in
            if newValue < albums.count {
                selectedAlbum = albums[newValue].name
                // sliderValue follows currentIndex during interaction; no need to set here
            }
        }
        .onAppear {
            if let selected = selectedAlbum,
               let index = albums.firstIndex(where: { $0.name == selected }) {
                currentIndex = index
                committedIndex = index
                sliderValue = Double(index)
            } else if !albums.isEmpty {
                currentIndex = 0
                committedIndex = 0
                sliderValue = 0.0
            }
            
            // Update CoverFlow when selected song changes
            updateCoverFlowIndexIfNeeded()
        }
        .onChange(of: selectedSong) { _ in
            updateCoverFlowIndexIfNeeded()
        }
        .focusable(false)
        .buttonStyle(PlainButtonStyle())
        .accentColor(.clear)
        .border(Color.clear, width: 0)
    }
    
    private func headerButton(_ title: String, sort: String, width: CGFloat? = nil) -> some View {
        Text(title)
            .fontWeight(.bold)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .onTapGesture { sortBy = sort }
    }

    private func selectAndPlay(album: AlbumInfo) {
        selectedAlbum = album.name
        onAlbumSelect(album.name)
    }

    private func playCurrentAlbum() {
        guard committedIndex < albums.count else { return }
        let album = albums[committedIndex]
        selectAndPlay(album: album)
    }
    
    // Function to play a specific song
    private func playSong(_ song: Song) {
        selectedSong = song
        // Set the correct playback context
        currentPlaybackSongs = songs.filter { $0.album == song.album }
        
        if isShuffleEnabled {
            // Only rebuild shuffle queue if it's empty or we're starting a new shuffle session
            if shuffleQueue.isEmpty {
                rebuildShuffleQueue(startingFrom: song)
            }
        }
        
        updateUpcomingSongs()
    }
    
    // Rebuild shuffle queue preserving current state
    private func rebuildShuffleQueue(startingFrom current: Song) {
        let context = currentPlaybackSongs
        let pool = context.filter { $0.id != current.id }
        shuffleQueue = pool.shuffled()
    }
    
    // Update upcoming songs based on shuffle and repeat modes
    private func updateUpcomingSongs() {
        guard let current = selectedSong else { return }
        
        // Clear upcoming songs if repeat one is enabled
        if isRepeatOne {
            // Don't update upcoming songs list - it should only show current song
            return
        }
        
        var upcoming: [Song] = []
        
        if isShuffleEnabled {
            // Show the next items from the persistent shuffle queue
            upcoming = Array(shuffleQueue.prefix(15))
        } else {
            // Get next sequential songs
            if let currentIndex = currentPlaybackSongs.firstIndex(where: { $0.id == current.id }) {
                let startIndex = currentIndex + 1
                let endIndex = min(startIndex + 15, currentPlaybackSongs.count)
                
                if startIndex < endIndex {
                    upcoming = Array(currentPlaybackSongs[startIndex..<endIndex])
                }
                
                // If we're near the end and repeat is enabled, add songs from the beginning
                if isRepeatEnabled && upcoming.count < 15 {
                    let additionalNeeded = 15 - upcoming.count
                    let additionalSongs = currentPlaybackSongs.prefix(additionalNeeded)
                    upcoming.append(contentsOf: additionalSongs)
                }
            }
        }
    }
    
    // Update CoverFlow index when selected song changes
    private func updateCoverFlowIndexIfNeeded() {
        guard let song = selectedSong,
              let albumIndex = albums.firstIndex(where: { $0.name == song.album }) else {
            return
        }
        
        if albumIndex != currentIndex {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentIndex = albumIndex
                sliderValue = Double(albumIndex)
                committedIndex = albumIndex
            }
        }
    }
}

struct AlbumInfo: Identifiable {
    let id = UUID()
    let name: String
    let artist: String
    let artwork: NSImage?

    init(name: String, artist: String, artworkData: Data?) {
        self.name = name
        self.artist = artist
        // Downsample artwork once to avoid large decode hitches during animation
        if let data = artworkData {
            self.artwork = AlbumInfo.downsampleImage(data: data, maxDimension: 600)
        } else {
            self.artwork = nil
        }
    }
    
    private static func downsampleImage(data: Data, maxDimension: CGFloat, scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }
        let pixelSize = Int(maxDimension * scale)
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        let image = NSImage(cgImage: cgImage, size: size)
        return image
    }
}

struct CoverFlowItemView: View {
    let album: AlbumInfo
    let index: Int
    let currentIndex: Int
    let geometry: GeometryProxy
    let isInteracting: Bool

    private var isCenterItem: Bool {
        index == currentIndex
    }

    private var distanceFromCenter: Int {
        abs(index - currentIndex)
    }

    var body: some View {
        ZStack {
            if let image = album.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black, radius: isCenterItem ? 8 : 3, x: 0, y: isCenterItem ? 8 : 3)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        gradient: Gradient(colors: [.gray, .white]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay(
                        VStack {
                            Text(album.name)
                                .font(.caption)
                                .foregroundColor(.black)
                                .multilineTextAlignment(.center)
                            Text(album.artist)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        .padding(4)
                    )
                    .shadow(color: .black, radius: isCenterItem ? 8 : 3, x: 0, y: isCenterItem ? 8 : 3)
            }
        }
        .scaleEffect(scaleEffect)
        .opacity(1.0)
        .rotation3DEffect(
            .degrees(rotationAngle),
            axis: (x: 0, y: 1, z: 0),
            anchor: rotationAnchor,
            perspective: 0.3
        )
        .compositingGroup()
        .animation(.easeInOut(duration: 0.3), value: currentIndex)
        .focusable(false)
        .buttonStyle(PlainButtonStyle())
        .accentColor(.clear)
        .border(Color.clear, width: 0)
    }

    private var scaleEffect: CGFloat {
        guard !isCenterItem else { return 1.2 }
        // Scale decreases as distance from center increases
        let scale = max(0.6, 1.0 - CGFloat(distanceFromCenter) * 0.15)
        return scale
    }

    private var rotationAngle: Double {
        guard !isCenterItem else { return 0 }
        let maxRotation: Double = 45.0
        let rotation = maxRotation * Double(min(distanceFromCenter, 3)) / 3.0
        return Double(index < currentIndex ? rotation : -rotation)
    }

    private var rotationAnchor: UnitPoint {
        guard !isCenterItem else { return .center }
        let diff = index - currentIndex
        return diff < 0 ? .trailing : .leading
    }
}
