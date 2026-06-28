import SwiftUI
import ImageIO

// Recreates the classic iTunes "Cover Flow" browsing mode: a horizontally
// scrubbable 3D carousel of album covers (with reflections), backed by a
// slider, album name/artist caption, and a song list below that can show
// either all songs or just the songs of the currently centered album.
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

    // Index of the album currently centered/highlighted in the carousel
    // (updates live while dragging the slider or tapping a cover).
    @State private var currentIndex: Int = 0
    @State private var committedIndex: Int = 0 // Index committed after interaction ends
    @State private var sliderValue: Double = 0.0
    @State private var showAllSongs = true // New state to toggle between all songs and album songs
    @State private var isInteracting = false // Track interaction to defer playback and commit index
    @StateObject private var playlistManager = PlaylistManager()

    // Size of the carousel's container, captured via GeometryReader, used to
    // compute a responsive cover size.
    @State private var containerSize: CGSize = .zero
    private var coverSize: CGFloat {
        // Base on height so covers fill the stage; cap so they don't overflow on wide windows
        let heightBased = containerSize.height * 0.7
        let widthCap = containerSize.width * 0.25
        return min(heightBased, widthCap)
    }

    // Only render a window of items around the current index
    // Rendering every album cover at once would be wasteful (and most are
    // off-screen anyway), so only a window of `visibleRange` items on each
    // side of the current index gets built into the view tree.
    private let visibleRange: Int = 6 // number of items to show on each side
    private var visibleAlbums: [(globalIndex: Int, album: AlbumInfo)] {
        guard !sortedAlbums.isEmpty else { return [] }
        let start = max(0, currentIndex - visibleRange)
        let end = min(sortedAlbums.count - 1, currentIndex + visibleRange)
        return (start...end).map { ($0, sortedAlbums[$0]) }
    }

    // Albums sorted alphabetically (using a normalized sort key, e.g. to
    // ignore leading articles/case) for stable carousel ordering.
    private var sortedAlbums: [AlbumInfo] {
        albums.sorted { a, b in
            normalizedSortKey(a.name) < normalizedSortKey(b.name)
        }
    }

    // Get songs for the committed album (prevents list churn while sliding)
    // Uses `committedIndex` rather than the live `currentIndex` so the song
    // list below doesn't flicker/reload while the user is still scrubbing.
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
                // Background layer: a dark gradient behind the carousel,
                // fading to solid black further down behind the text/slider.
                VStack(spacing: 0) {
                    backgroundColor
                        .frame(maxWidth: .infinity, maxHeight: 280)
                    Color.black // This stretches down to fill behind the text/slider
                }

                // CoverFlow & Reflections (Middle)
                // The actual 3D carousel content, sized from the available geometry.
                GeometryReader { geometry in
                    coverFlowContent(geometry: geometry)
                        .onAppear { containerSize = geometry.size }
                        .onChange(of: geometry.size) { newSize in
                            containerSize = newSize
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: 280)

                // Text & Slider (Front)
                // Foreground layer: album name/artist caption plus the scrub slider,
                // positioned below the carousel area (Color.clear reserves that space).
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 280)

                    albumInfoSection
                    sliderSection
                }
            }
            .contentShape(Rectangle())

            controlsSection

            // Song list beneath the carousel — either every song in the
            // library or just the centered album's songs, depending on the toggle.
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
            // Whenever the committed (settled) index changes, propagate the
            // newly centered album out via the `selectedAlbum` binding.
            if newValue < sortedAlbums.count {
                selectedAlbum = sortedAlbums[newValue].name
                // sliderValue follows currentIndex during interaction
            }
        }
        .onAppear {
            // On first appearance, jump straight to whichever album is
            // already selected (if any), otherwise default to the first album.
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
            // Keep the carousel in sync if a song gets selected elsewhere in
            // the app (e.g. from a different view), by jumping to its album.
            updateCoverFlowIndexIfNeeded()
        }
        .focusable(false)
        .buttonStyle(PlainButtonStyle())
    }

    // Dark vertical gradient used behind the carousel stage.
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

    // Caption showing the centered album's name and artist, shown above the slider.
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

    // The "1 ... N" scrub bar beneath the album caption, used to quickly
    // jump to any album by index. Hidden when there's only one album.
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
                                // Once the user releases the slider, commit
                                // the index and (after a short delay so the
                                // settle animation can finish) start playback.
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

    // Row beneath the carousel/slider holding the "All Songs" / "Album
    // Songs" toggle button that controls which songs the list below shows.
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

    // Builds the carousel's ZStack of CoverFlowItemView covers, positioning
    // each visible album cover horizontally based on its distance from the
    // current center index, and wiring up tap-to-select behavior.
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
                    // Tapping a cover animates it to the center, then commits
                    // the index and starts playback after the animation settles.
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

    // Computes the horizontal screen position for a cover at `index`,
    // relative to `currentIndex`. The centered cover sits at `centerX`;
    // covers to either side are packed closer together as they get farther
    // from center (an "eased" spacing), and are clamped so they never
    // render past the carousel's left/right edges.
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

    // Marks `album` as selected and notifies the parent via onAlbumSelect.
    private func selectAndPlay(album: AlbumInfo) {
        selectedAlbum = album.name
        onAlbumSelect(album.name)
    }

    // Plays the album currently sitting at `committedIndex` (used after the
    // slider settles on a new position).
    private func playCurrentAlbum() {
        guard committedIndex < sortedAlbums.count else { return }
        let album = sortedAlbums[committedIndex]
        selectAndPlay(album: album)
    }

    // Update CoverFlow index when selected song changes
    // If the externally-selected song belongs to a different album than the
    // one currently centered, animate the carousel over to that album.
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

// Lightweight, identifiable model representing one album in the carousel:
// its name, artist, and a pre-downsampled artwork image (to avoid decoding
// full-resolution artwork during animation, which would cause hitches).
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

    // Uses ImageIO's thumbnail generation to decode and downsample artwork
    // data directly to a target pixel size (scaled for the screen's backing
    // scale factor), which is far cheaper than decoding full-size then resizing.
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

// Renders a single album cover + its reflection in the carousel, applying
// 3D rotation, saturation/brightness falloff, and shadow based on how far
// the item is from the centered index.
struct CoverFlowItemView: View {
    let album: AlbumInfo
    let index: Int
    let currentIndex: Int
    let geometry: GeometryProxy
    let isInteracting: Bool

    // Whether this is the cover currently centered in the carousel.
    private var isCenterItem: Bool {
        index == currentIndex
    }

    // How many positions away from center this item is.
    private var distanceFromCenter: Int {
        abs(index - currentIndex)
    }

    // Center item is fully saturated; side items get progressively desaturated.
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
            // The cover artwork, tilted in 3D away from the camera unless centered.
            coverImage
                .rotation3DEffect(
                    .degrees(rotationAngle),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: rotationAnchor,
                    perspective: 0.25
                )

            // Reflection
            // A second copy of the same cover, flipped vertically and faded
            // out via a gradient mask, to simulate a glossy reflective surface.
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

    // The actual cover artwork view: the album's artwork image if available,
    // otherwise a generated gradient placeholder with a music-note icon and
    // album name. Shadow intensity/blur increases for the centered item.
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

    // Side covers shrink slightly the farther they are from center
    // (currently computed but not applied anywhere in body — see usage notes).
    private var scaleEffect: CGFloat {
        guard !isCenterItem else { return 1.0 }
        return max(0.65, 1.0 - CGFloat(distanceFromCenter) * 0.1)
    }

    // 3D rotation angle for this cover: 0° when centered, otherwise a base
    // rotation (~65°) plus a small extra amount that grows with distance
    // from center (capped at +8°), flipped in sign depending on which side
    // of the center the cover is on.
    private var rotationAngle: Double {
        guard !isCenterItem else { return 0 }
        let baseRotation = 65.0
        let extra = min(Double(distanceFromCenter - 1) * 3.0, 8.0)
        let rotation = baseRotation + extra
        return index < currentIndex ? rotation : -rotation
    }

    // The anchor point the 3D rotation pivots around: centered covers pivot
    // around their own center, while side covers pivot from their inner edge
    // (the edge facing the center) so they appear to "fan out".
    private var rotationAnchor: UnitPoint {
        guard !isCenterItem else { return .center }
        let diff = index - currentIndex
        return diff < 0 ? .trailing : .leading
    }
}

// Custom-drawn slider used beneath the Cover Flow carousel, styled to look
// like the classic iTunes scrub bar (dark capsule track + an oval thumb with
// a gradient/highlight), driven by a raw DragGesture rather than the system Slider.
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
                        // Drag the thumb directly (rather than relying on a
                        // system Slider) so the track/thumb can be fully
                        // custom-styled while still updating `value` live.
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
