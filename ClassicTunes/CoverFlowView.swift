import SwiftUI
import ImageIO

struct CoverFlowView: View {
    let albums: [AlbumInfo]
    @Binding var selectedAlbum: String?
    @Binding var isCoverFlowActive: Bool
    var onAlbumSelect: (String) -> Void
    var songs: [Song] = []

    // Added bindings for playback management
    @Binding var selectedSong: Song?
    @Binding var currentPlaybackSongs: [Song]
    @Binding var shuffleQueue: [Song]
    @Binding var isShuffleEnabled: Bool
    @Binding var isRepeatOne: Bool
    @Binding var isRepeatEnabled: Bool

    @State private var currentIndex: Int = 0
    @State private var committedIndex: Int = 0 // Index committed after interaction ends
    @State private var sliderValue: Double = 0.0
    @State private var showAllSongs = true // New state to toggle between all songs and album songs
    @State private var isInteracting = false // Track interaction to defer playback and commit index
    @StateObject private var playlistManager = PlaylistManager()

    @State private var containerSize: CGSize = .zero
    private var coverSize: CGFloat {
        // Base on height so covers fill the stage; cap so they don't overflow on wide windows
        let heightBased = containerSize.height * 0.7
        let widthCap = containerSize.width * 0.25
        return min(heightBased, widthCap)
    }

    // Only render a window of items around the current index
    private let visibleRange: Int = 6 // number of items to show on each side
    private var visibleAlbums: [(globalIndex: Int, album: AlbumInfo)] {
        guard !sortedAlbums.isEmpty else { return [] }
        let start = max(0, currentIndex - visibleRange)
        let end = min(sortedAlbums.count - 1, currentIndex + visibleRange)
        return (start...end).map { ($0, sortedAlbums[$0]) }
    }

    private var sortedAlbums: [AlbumInfo] {
        albums.sorted { a, b in
            normalizedSortKey(a.name) < normalizedSortKey(b.name)
        }
    }

    // Get songs for the committed album (prevents list churn while sliding)
    private var albumSongs: [Song] {
        guard !sortedAlbums.isEmpty && committedIndex < sortedAlbums.count else { return [] }
        let currentAlbum = sortedAlbums[committedIndex]
        return songs.filter { $0.album == currentAlbum.name }
    }

    // All songs or album songs based on toggle
    private var displayedSongs: [Song] {
        showAllSongs ? songs : albumSongs
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // The Backgrounds (Back)
                VStack(spacing: 0) {
                    backgroundColor
                        .frame(maxWidth: .infinity, maxHeight: 280)
                    Color.black // This stretches down to fill behind the text/slider
                }

                // CoverFlow & Reflections (Middle)
                GeometryReader { geometry in
                    coverFlowContent(geometry: geometry)
                        .onAppear { containerSize = geometry.size }
                        .onChange(of: geometry.size) { newSize in
                            containerSize = newSize
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: 280)

                // Text & Slider (Front)
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 280)
                    
                    albumInfoSection
                    sliderSection
                }
            }
            .contentShape(Rectangle())

            controlsSection
            
            SongListView(
                isAlbumView: false,
                songs: songs,
                onSongSelect: { song in
                    onAlbumSelect(song.album)
                    selectedSong = song
                },
                selectedSong: $selectedSong,
                onAlbumSelect: { albumName in
                    let albumSongs = songs.filter { $0.album == albumName }
                    if let _ = albumSongs.first {
                        currentPlaybackSongs = albumSongs
                        onAlbumSelect(albumName)
                    }
                },
                playlistSongs: displayedSongs, // This will be filtered based on showAllSongs
                onAddToPlaylist: { song in
                    // Handle adding song to playlist
                    print("Adding \(song.title) to playlist")
                }
            )
            .environmentObject(playlistManager)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
            .padding(.top, 0)

            Spacer()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(Rectangle())
        .onChange(of: committedIndex) { newValue in
            if newValue < sortedAlbums.count {
                selectedAlbum = sortedAlbums[newValue].name
                // sliderValue follows currentIndex during interaction
            }
        }
        .onAppear {
            if let selected = selectedAlbum,
               let index = sortedAlbums.firstIndex(where: { $0.name == selected }) {
                currentIndex = index
                committedIndex = index
                sliderValue = Double(index)
            } else if !sortedAlbums.isEmpty {
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
    }

    private var backgroundColor: some View {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color(white: 0.18), location: 0.0),
                .init(color: Color(white: 0.05), location: 0.55),
                .init(color: Color.black, location: 1.0)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var albumInfoSection: some View {
        Group {
            if !sortedAlbums.isEmpty && currentIndex < sortedAlbums.count {
                VStack(alignment: .center, spacing: 4) {
                    Text(sortedAlbums[currentIndex].name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Text(sortedAlbums[currentIndex].artist)
                        .font(.system(size: 17))
                        .foregroundColor(Color(white: 0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
    }

    private var sliderSection: some View {
        Group {
            if sortedAlbums.count > 1 {
                HStack {
                    Text("1")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.5))
                        .frame(width: 24, alignment: .leading)

                    ClassicCoverFlowSlider(
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
                        range: 0...Double(sortedAlbums.count - 1),
                        onEditingChanged: { isEditing in
                            isInteracting = isEditing
                            if !isEditing {
                                committedIndex = currentIndex
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    playCurrentAlbum()
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    isInteracting = false
                                }
                            }
                        }
                    )
                    .padding(.horizontal, 4)

                    Text("\(sortedAlbums.count)")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.5))
                        .frame(width: 24, alignment: .trailing)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 8)
            }
        }
    }

    private var controlsSection: some View {
        HStack {
            Spacer()

            // Toggle button to switch between all songs and album songs
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
                        .fill(Color.accentColor.opacity(0.15))
                )
                .foregroundColor(.accentColor)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 12)
            .padding(.top, 4)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func coverFlowContent(geometry: GeometryProxy) -> some View {
        let size = geometry.size
        let coverWidth = coverSize
        // Each item's frame holds cover + reflection, so the cover occupies the top half
        let frameHeight = coverWidth * 2.0  // cover + equal-height reflection area
        let centerX = size.width / 2
        let coverMargin = coverWidth / 2 + size.width * 0.04
        let leftEdge = coverMargin
        let rightEdge = size.width - coverMargin

        let leftCount = currentIndex
        let rightCount = sortedAlbums.count - currentIndex - 1

        return ZStack {
            ForEach(visibleAlbums, id: \.globalIndex) { item in
                let index = item.globalIndex
                let album = item.album

                let xPosition = calculateXPosition(
                    for: index,
                    currentIndex: currentIndex,
                    leftCount: leftCount,
                    rightCount: rightCount,
                    leftEdge: leftEdge,
                    rightEdge: rightEdge,
                    centerX: centerX,
                    coverWidth: coverWidth
                )

                CoverFlowItemView(
                    album: album,
                    index: index,
                    currentIndex: currentIndex,
                    geometry: geometry,
                    isInteracting: isInteracting
                )
                .frame(width: coverWidth, height: frameHeight)
                .position(x: xPosition, y: size.height / 2 + 100)
                .zIndex(Double(sortedAlbums.count) - abs(Double(index - currentIndex)))
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
            }
        }
    }

    private func calculateXPosition(
        for index: Int,
        currentIndex: Int,
        leftCount: Int,
        rightCount: Int,
        leftEdge: CGFloat,
        rightEdge: CGFloat,
        centerX: CGFloat,
        coverWidth: CGFloat
    ) -> CGFloat {
        // Tighter spacing for side items — real CoverFlow packs them close together
        let sideSpacing = coverWidth * 0.42

        if index == currentIndex {
            return centerX
        }

        if index < currentIndex {
            // Left side: stack items to the left of center with decreasing spacing further away
            let distance = CGFloat(currentIndex - index)
            // Add a small easing so spacing compresses as items get farther
            let eased = sideSpacing * (0.85 + 0.15 / max(1.0, distance))
            let position = centerX - (coverWidth / 2) - (distance * eased)
            // Clamp to not go past the left edge
            return max(leftEdge, position)
        } else {
            // Right side
            let distance = CGFloat(index - currentIndex)
            let eased = sideSpacing * (0.85 + 0.15 / max(1.0, distance))
            let position = centerX + (coverWidth / 2) + (distance * eased)
            return min(rightEdge, position)
        }
    }

    private func selectAndPlay(album: AlbumInfo) {
        selectedAlbum = album.name
        onAlbumSelect(album.name)
    }

    private func playCurrentAlbum() {
        guard committedIndex < sortedAlbums.count else { return }
        let album = sortedAlbums[committedIndex]
        selectAndPlay(album: album)
    }

    // Update CoverFlow index when selected song changes
    private func updateCoverFlowIndexIfNeeded() {
        guard let song = selectedSong,
              let albumIndex = sortedAlbums.firstIndex(where: { $0.name == song.album }) else {
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

    private var itemSaturation: Double {
        return isCenterItem ? 1.0 : max(0.5, 1.0 - (Double(distanceFromCenter) * 0.2))
    }

    // Brightness drops off for far items
    private var itemBrightness: Double {
        return isCenterItem ? 0.0 : max(-0.35, -Double(distanceFromCenter) * 0.1)
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Main cover
            coverImage
                .rotation3DEffect(
                    .degrees(rotationAngle),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: rotationAnchor,
                    perspective: 0.25
                )

            // Reflection
            coverImage
                .rotation3DEffect(
                    .degrees(rotationAngle),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: rotationAnchor,
                    perspective: 0.25
                )
                .scaleEffect(x: 1, y: -1) // flip vertically
                .mask(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.black.opacity(0.45),
                            Color.black.opacity(0.0)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .saturation(itemSaturation)
        .brightness(itemBrightness)
        .compositingGroup()
        .animation(.easeInOut(duration: 0.3), value: currentIndex)
        .focusable(false)
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private var coverImage: some View {
        if let image = album.artwork {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .shadow(
                    color: .black.opacity(isCenterItem ? 0.7 : 0.4),
                    radius: isCenterItem ? 14 : 4,
                    x: 0,
                    y: isCenterItem ? 6 : 2
                )
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(
                    gradient: Gradient(colors: [
                        Color(white: 0.35),
                        Color(white: 0.18)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(
                    VStack(spacing: 4) {
                        Image(systemName: "music.note")
                            .font(.system(size: 24))
                            .foregroundColor(Color(white: 0.6))
                        Text(album.name)
                            .font(.caption2)
                            .foregroundColor(Color(white: 0.7))
                            .multilineTextAlignment(.center)
                    }
                    .padding(6)
                )
                .shadow(
                    color: .black.opacity(isCenterItem ? 0.7 : 0.4),
                    radius: isCenterItem ? 14 : 4,
                    x: 0,
                    y: isCenterItem ? 6 : 2
                )
        }
    }

    private var scaleEffect: CGFloat {
        guard !isCenterItem else { return 1.0 }
        return max(0.65, 1.0 - CGFloat(distanceFromCenter) * 0.1)
    }

    private var rotationAngle: Double {
        guard !isCenterItem else { return 0 }
        let baseRotation = 65.0
        let extra = min(Double(distanceFromCenter - 1) * 3.0, 8.0)
        let rotation = baseRotation + extra
        return index < currentIndex ? rotation : -rotation
    }

    private var rotationAnchor: UnitPoint {
        guard !isCenterItem else { return .center }
        let diff = index - currentIndex
        return diff < 0 ? .trailing : .leading
    }
}

struct ClassicCoverFlowSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let trackHeight: CGFloat = 10
            let thumbWidth: CGFloat = 36
            let thumbHeight: CGFloat = 16
            
            // Calculate usable width so the thumb doesn't slide out of bounds
            let usableWidth = geo.size.width - thumbWidth
            // Normalize value between 0.0 and 1.0
            let percentage = (usableWidth > 0) ? (value - range.lowerBound) / (range.upperBound - range.lowerBound) : 0
            
            // Calculate positions
            let thumbX = (thumbWidth / 2) + (usableWidth * CGFloat(percentage))
            let centerY = geo.size.height / 2
            
            ZStack {
                // Track: Uniform dark grey with an inner shadow/border look
                Capsule()
                    .fill(Color(white: 0.15))
                    .overlay(
                        Capsule().stroke(Color(white: 0.3), lineWidth: 1)
                    )
                    .frame(height: trackHeight)
                    .position(x: geo.size.width / 2, y: centerY)
                
                // Thumb: Wide oval, dark gradient, bright top highlight
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color(white: 0.45), Color(white: 0.15)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Capsule().stroke(Color.black, lineWidth: 1.5)
                    )
                    .overlay(
                        Capsule().stroke(Color(white: 0.6), lineWidth: 0.5).padding(1)
                    )
                    .frame(width: thumbWidth, height: thumbHeight)
                    .position(x: thumbX, y: centerY)
                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                onEditingChanged(true)
                                // Calculate new value based on drag position
                                let newOffset = drag.location.x - (thumbWidth / 2)
                                let clampedOffset = max(0, min(newOffset, usableWidth))
                                let newPercentage = clampedOffset / usableWidth
                                value = range.lowerBound + Double(newPercentage) * (range.upperBound - range.lowerBound)
                            }
                            .onEnded { _ in
                                onEditingChanged(false)
                            }
                    )
            }
        }
        .frame(height: 24) // Comfortable hit target height
    }
}

