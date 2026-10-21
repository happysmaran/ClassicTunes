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

    // Height of the whole Cover Flow view (stage + caption + slider + controls
    // + song list), used to detect when vertical space is tight.
    @State private var viewHeight: CGFloat = 0

    // Base height of the carousel stage. It is 280pt unless the window is too
    // short to also leave `CoverFlowMetrics.minSongListHeight` for the song
    // list, in which case the stage shrinks and the caption/slider block slides
    // up over the bottom of it (hiding the reflections behind it).
    private var baseStageHeight: CGFloat {
        guard viewHeight > 0 else { return CoverFlowMetrics.fullStageHeight }
        let budget = viewHeight - CoverFlowMetrics.reservedBelowStage
        return min(CoverFlowMetrics.fullStageHeight, max(CoverFlowMetrics.minStageHeight, budget))
    }

    // Height the layout actually gives the black box behind the carousel
    // (measured), and the smallest height its content needs.
    @State private var boxHeight: CGFloat = 0
    private var naturalBoxHeight: CGFloat {
        baseStageHeight + CoverFlowMetrics.captionAndSliderHeight + CoverFlowMetrics.bottomMargin
    }

    // Height of the region above the caption/slider block (the gradient area).
    private var stageRegionHeight: CGFloat {
        let box = max(boxHeight, naturalBoxHeight)
        return box - CoverFlowMetrics.captionAndSliderHeight - CoverFlowMetrics.bottomMargin
    }

    // The caption and slider are pinned to the bottom of the box, a fixed
    // distance from its edge. Any spare height goes to the stage, so covers grow
    // on large windows (up to `maxStageHeight`); beyond that the extra is just
    // more backdrop above the stage.
    private var stageHeight: CGFloat {
        min(CoverFlowMetrics.maxStageHeight, max(baseStageHeight, stageRegionHeight))
    }

    // 0 with plenty of vertical space, ramping to 1 as the stage is squeezed
    // (over the first 40pt of lost height, so the change is gradual).
    private var stageSqueeze: CGFloat {
        min(1, max(0, (CoverFlowMetrics.fullStageHeight - baseStageHeight) / 40))
    }

    // How strongly to back the caption/slider block with black so the
    // reflections that run behind it are hidden: when vertical space is tight,
    // or when the window is narrow enough to count as compact. (This no longer
    // moves the covers; their vertical position comes only from `topMargin`.)
    private var dropAmount: CGFloat {
        max(stageSqueeze, CoverFlowMetrics.compactness(forWidth: containerSize.width))
    }

    private var coverSize: CGFloat {
        // Base on height so covers fill the stage; cap so they don't overflow on wide windows
        let heightBased = containerSize.height * 0.7
        let widthCap = containerSize.width * 0.25
        let baseSize = min(heightBased, widthCap)

        // Side covers are tilted toward the camera, so their outer edges are
        // drawn taller than the cover itself (see CoverFlowMetrics). On smaller
        // windows that makes them poke out of the top of the stage and look
        // bigger than the centered cover. Shrink the covers just enough that
        // the magnified edges fit under the usual top gap, fading the shrink
        // in as the window gets narrower so larger windows are unchanged.
        let fitSize = CoverFlowMetrics.compactFitGap / ((CoverFlowMetrics.edgeMagnification - 1) / 2)
        let compactness = CoverFlowMetrics.compactness(forWidth: containerSize.width)
        let compactSize = baseSize + (min(baseSize, fitSize) - baseSize) * compactness

        // Hard limit: with the top margin reserved (see `coverFlowContent`), the
        // magnified outer edges must still fit inside the stage height,
        // regardless of window width.
        let backdropAboveStage = max(0, stageRegionHeight - stageHeight)
        let stageLimit = max(0, (containerSize.height - 4 - CoverFlowMetrics.topMargin + backdropAboveStage)
            / CoverFlowMetrics.edgeMagnification)
        return min(compactSize, stageLimit)
    }

    // Only render a window of items around the current index
    // Rendering every album cover at once would be wasteful (and most are
    // off-screen anyway), so only a window of `visibleRange` items on each
    // side of the current index gets built into the view tree.
    // The count is derived from how many covers it takes to fan out to the
    // window edge at the current cover size, so a tighter fan shows more covers.
    private var visibleRange: Int {
        let size = coverSize
        guard size > 0, containerSize.width > 0 else { return CoverFlowMetrics.minVisibleRange }
        let available = max(0, containerSize.width / 2 - size / 2)
        var count = 1
        while count < CoverFlowMetrics.maxVisibleRange,
              CoverFlowMetrics.innerEdgeOffset(forDistance: count, coverSize: size) < available {
            count += 1
        }
        // One extra so the last cover bleeds off the edge instead of stopping short.
        return min(CoverFlowMetrics.maxVisibleRange, max(CoverFlowMetrics.minVisibleRange, count + 1))
    }
    private var visibleAlbums: [(globalIndex: Int, album: AlbumInfo)] {
        guard !sortedAlbums.isEmpty else { return [] }
        let start = max(0, currentIndex - visibleRange)
        let end = min(sortedAlbums.count - 1, currentIndex + visibleRange)
        return (start...end).map { ($0, sortedAlbums[$0]) }
    }

    // `albums` arrives already sorted (by `AlbumListCache`, using the shared
    // normalized sort key), so there is no need to re-sort on every read.
    private var sortedAlbums: [AlbumInfo] { albums }

    // Songs for the committed album (prevents list churn while sliding).
    // Uses `committedIndex` rather than the live `currentIndex` so the song
    // list below doesn't flicker/reload while the user is still scrubbing.
    // Each album already carries its songs, so this is a lookup, not a filter.
    private var albumSongs: [Song] {
        guard committedIndex < sortedAlbums.count else { return [] }
        return sortedAlbums[committedIndex].songs
    }

    // All songs or album songs based on toggle
    private var displayedSongs: [Song] {
        showAllSongs ? songs : albumSongs
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // The black "box" behind the carousel. It is greedy, so it takes
            // whatever height the layout gives it, but its own minimum is just the
            // natural height of the stage + caption + slider. The visible content
            // is an overlay so it never feeds back into the box's size, which lets
            // us measure the box and lay the content out within it.
            Color.black
                .frame(maxWidth: .infinity, minHeight: naturalBoxHeight)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { boxHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { newHeight in
                                boxHeight = newHeight
                            }
                    }
                )
                .overlay(alignment: .top) {
                    // The Backgrounds (Back)
                    // A dark gradient behind the carousel, fading to solid black
                    // further down behind the text/slider.
                    backgroundColor
                        .frame(maxWidth: .infinity)
                        .frame(height: stageRegionHeight)
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        // CoverFlow & Reflections (Middle)
                        // The actual 3D carousel content, sized from the available geometry.
                        GeometryReader { geometry in
                            coverFlowContent(geometry: geometry)
                                .onAppear { containerSize = geometry.size }
                                .onChange(of: geometry.size) { newSize in
                                    containerSize = newSize
                                }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: stageHeight)

                        // Text & Slider (Front)
                        // Foreground layer: album name/artist caption plus the scrub
                        // slider, pinned to the bottom of the box.
                        VStack(spacing: 0) {
                            albumInfoSection
                            sliderSection
                        }
                        // When the covers are dropped the reflections sit behind this block, so
                        // give it a black backing (fading in at its top edge) to hide
                        // them. Fully transparent when there is room.
                        .background(
                            LinearGradient(
                                stops: [
                                    .init(color: .black.opacity(0), location: 0),
                                    .init(color: .black.opacity(dropAmount), location: 0.25),
                                    .init(color: .black.opacity(dropAmount), location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    .padding(.bottom, CoverFlowMetrics.bottomMargin)
                }
                // The outermost covers fade away into the distance at each side.
                .overlay(alignment: .top) {
                    edgeFade
                        .frame(height: stageRegionHeight)
                        .allowsHitTesting(false)
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
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { newHeight in
                        viewHeight = newHeight
                    }
            }
        )
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

    // Fades the carousel out at the left and right edges. It re-draws the stage
    // backdrop (so it blends seamlessly) through a mask that is opaque at the
    // edges and clear toward the middle, on top of the covers. Cheap: two small
    // gradients, nothing is rendered offscreen per cover.
    private var edgeFade: some View {
        let width = max(CoverFlowMetrics.edgeFadeMinWidth,
                        min(CoverFlowMetrics.edgeFadeMaxWidth,
                            containerSize.width * CoverFlowMetrics.edgeFadeFraction))
        return backgroundColor
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.6), location: 0.35),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width)

                    Spacer(minLength: 0)

                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.6), location: 0.35),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .trailing,
                        endPoint: .leading
                    )
                    .frame(width: width)
                }
            )
    }

    // Dark vertical gradient used behind the carousel stage, with a soft
    // overhead "spotlight" glow centered above the stage.
    private var backgroundColor: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(white: 0.18), location: 0.0),
                    .init(color: Color(white: 0.05), location: 0.55),
                    .init(color: Color.black, location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                gradient: Gradient(colors: [
                    Color.white.opacity(0.08),
                    Color.white.opacity(0.0)
                ]),
                center: .init(x: 0.5, y: 0.1),
                startRadius: 0,
                endRadius: 300
            )
        }
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
    // jump to any album by index.
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
                        .fill(.tint.opacity(0.15))
                )
                .foregroundStyle(.tint)
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
        // Keep a small gap above the cover, proportional to the stage
        // height rather than a fixed point offset, so the stack of
        // cover+reflection stays inside the visible stage instead of
        // sliding off it on unusually short/tall windows.
        // Side covers are tilted toward the camera, so their outer top corners
        // are drawn higher than the cover itself (by up to `edgeMagnification`).
        // Whatever the window size, keep the highest of those corners at least
        // `topMargin` below the top border of the box, at every size. Backdrop
        // above the stage (when the stage is capped) counts toward that margin.
        let backdropAboveStage = max(0, stageRegionHeight - stageHeight)
        let topGap = max(0, coverWidth * (CoverFlowMetrics.edgeMagnification - 1) / 2
            + CoverFlowMetrics.topMargin - backdropAboveStage)
        // The covers are placed purely by the top margin above; nothing else
        // shifts them vertically, so that margin is the same at every size.
        let itemCenterY = topGap + frameHeight / 2

        return ZStack {
            // Soft pool of light on the "floor" directly beneath the centered cover
            Ellipse()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.10),
                            Color.white.opacity(0.0)
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: coverWidth * 0.9
                    )
                )
                .frame(width: coverWidth * 1.8, height: coverWidth * 0.6)
                .position(x: centerX, y: itemCenterY)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

            ForEach(visibleAlbums, id: \.globalIndex) { item in
                let index = item.globalIndex
                let album = item.album

                let xPosition = calculateXPosition(
                    for: index,
                    currentIndex: currentIndex,
                    centerX: centerX,
                    coverWidth: coverWidth
                )

                CoverFlowItemView(
                    album: album,
                    index: index,
                    currentIndex: currentIndex,
                    geometry: geometry,
                    isInteracting: isInteracting,
                    coverWidth: coverWidth
                )
                .frame(width: coverWidth, height: frameHeight)
                .position(x: xPosition, y: itemCenterY)
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

    // Computes the horizontal screen position (cell center) for a cover at
    // `index`, relative to `currentIndex`. The centered cover sits at `centerX`.
    // Side covers pivot on their inner edge, so each one is placed by where that
    // edge falls: a small gap from the centered cover's edge, then steps that
    // shrink toward a minimum (see `CoverFlowMetrics.innerEdgeOffset`). Spacing
    // scales with the cover size rather than being stretched to the window
    // width, so the fan stays tight; `visibleRange` supplies enough covers to
    // reach the edge.
    private func calculateXPosition(
        for index: Int,
        currentIndex: Int,
        centerX: CGFloat,
        coverWidth: CGFloat
    ) -> CGFloat {
        if index == currentIndex {
            return centerX
        }

        let distance = abs(index - currentIndex)
        let offset = CoverFlowMetrics.innerEdgeOffset(forDistance: distance, coverSize: coverWidth)
        if index < currentIndex {
            // Left side: the cell's trailing edge is the inner (pivot) edge.
            let innerEdge = centerX - coverWidth / 2 - offset
            return innerEdge - coverWidth / 2
        } else {
            // Right side: the cell's leading edge is the inner (pivot) edge.
            let innerEdge = centerX + coverWidth / 2 + offset
            return innerEdge + coverWidth / 2
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

// Shared geometry constants for the carousel, so layout code can account for
// how the 3D tilt changes the size of side covers.
enum CoverFlowMetrics {
    static let perspective: CGFloat = 0.25
    static let baseRotation: Double = 65
    static let maxExtraRotation: Double = 8

    // Vertical layout. The carousel stage is normally 280pt tall; below it sit
    // the caption (~63pt), slider (~40pt) and controls row (~28pt) — measured
    // by eye, so approximate — and the song list, which is guaranteed at least
    // `minSongListHeight` before the stage is allowed to shrink.
    static let fullStageHeight: CGFloat = 280
    static let minStageHeight: CGFloat = 170
    // On roomy windows the stage may grow past `fullStageHeight` (bigger covers)
    // up to this height; the caption/slider block stays pinned to the bottom,
    // `bottomMargin` from the edge.
    static let maxStageHeight: CGFloat = 520
    static let bottomMargin: CGFloat = 16
    // Width of the fade at each side, as a fraction of the stage width, clamped.
    static let edgeFadeFraction: CGFloat = 0.09
    static let edgeFadeMinWidth: CGFloat = 48
    static let edgeFadeMaxWidth: CGFloat = 160
    // Minimum space between the highest corner of any tilted cover and the top
    // border of the carousel box.
    static let topMargin: CGFloat = 20
    // Reference room used only to decide how much to shrink covers on compact
    // windows (cover size at which the tilted edges' overshoot equals this gap).
    // Positioning always uses `topMargin`.
    static let compactFitGap: CGFloat = 24
    static let minSongListHeight: CGFloat = 160
    static let captionAndSliderHeight: CGFloat = 63 + 40
    static let reservedBelowStage: CGFloat = captionAndSliderHeight + 28 + minSongListHeight

    // With a rotation about a cover's inner edge, SwiftUI places the eye at
    // (cover size / perspective) from the view, so the outer edge, which swings
    // toward the camera by size * sin(angle), is magnified by
    // 1 / (1 - perspective * sin(angle)). This is the worst case (steepest tilt)
    // and is independent of the cover's size.
    static var edgeMagnification: CGFloat {
        let angle = (baseRotation + maxExtraRotation) * .pi / 180
        return 1 / (1 - perspective * CGFloat(sin(angle)))
    }

    // Fan spacing, in multiples of the cover size. Distances are measured from
    // the centered cover's edge to a side cover's inner (pivot) edge.
    static let firstGap: CGFloat = 0.18       // centered cover → first neighbor
    static let nearStep: CGFloat = 0.30       // spacing of the 2nd cover; later steps shrink…
    static let farStep: CGFloat = 0.15        // …toward this minimum
    static let stepDecay: CGFloat = 0.78      // how quickly steps shrink
    static let minVisibleRange = 6
    static let maxVisibleRange = 15           // caps rendering cost on wide windows

    static func innerEdgeOffset(forDistance distance: Int, coverSize: CGFloat) -> CGFloat {
        guard distance >= 1 else { return 0 }
        var offset = firstGap
        if distance >= 2 {
            for k in 2...distance {
                offset += farStep + (nearStep - farStep) * pow(stepDecay, CGFloat(k - 2))
            }
        }
        return offset * coverSize
    }

    // 0 for roomy windows, ramping to 1 for compact ones (≈13-inch displays
    // and smaller windows). Width in points.
    static func compactness(forWidth width: CGFloat) -> CGFloat {
        let roomy: CGFloat = 1400
        let compact: CGFloat = 1000
        return min(1, max(0, (roomy - width) / (roomy - compact)))
    }
}

// Lightweight, identifiable model representing one album in the carousel.
// It only holds the raw artwork bytes (a cheap, copy-on-write reference to
// the song's data); decoding happens lazily and off the main thread through
// `AlbumArtworkLoader`, and only for covers that are actually on screen.
struct AlbumInfo: Identifiable {
    // Album names are unique within the carousel, so the name makes a stable
    // identity that survives the list being rebuilt.
    var id: String { name }
    let name: String
    let artist: String
    let artworkData: Data?
    // Every song in this album, in library order, so per-album lookups don't
    // need to filter the whole library.
    let songs: [Song]
    // Changes whenever the artwork changes; keys the decoded-image cache and
    // re-triggers loading if the album's artwork is edited.
    let artworkKey: String

    init(name: String, artist: String, artworkData: Data?, songs: [Song] = []) {
        self.name = name
        self.artist = artist
        self.artworkData = artworkData
        self.songs = songs
        if let data = artworkData {
            self.artworkKey = "\(name)|\(data.count)|\(data.prefix(64).hashValue)"
        } else {
            self.artworkKey = "\(name)|none"
        }
    }
}

// Builds the sorted album list for Cover Flow and memoizes it, so it is only
// recomputed when the library (or the filtered/selected song set) actually
// changes rather than on every SwiftUI body evaluation.
final class AlbumListCache {
    private var signature: Int?
    private var albums: [AlbumInfo] = []

    func albums(for songs: [Song]) -> [AlbumInfo] {
        // Cheap fingerprint of everything the carousel depends on. Artwork is
        // represented by its byte count to avoid hashing large blobs.
        var hasher = Hasher()
        hasher.combine(songs.count)
        for song in songs {
            hasher.combine(song.id)
            hasher.combine(song.title)
            hasher.combine(song.album)
            hasher.combine(song.artist)
            hasher.combine(song.trackNumber)
            hasher.combine(song.discNumber)
            hasher.combine(song.playCount)
            hasher.combine(song.artworkData?.count ?? -1)
        }
        let newSignature = hasher.finalize()
        if newSignature == signature { return albums }

        // Group songs by album in a single pass, remembering library order.
        var songsByAlbum: [String: [Song]] = [:]
        for song in songs {
            songsByAlbum[song.album, default: []].append(song)
        }

        // Compute each sort key once rather than inside the comparator.
        var entries: [(key: String, name: String, songs: [Song])] = []
        entries.reserveCapacity(songsByAlbum.count)
        for (name, albumSongs) in songsByAlbum {
            entries.append((key: normalizedSortKey(name), name: name, songs: albumSongs))
        }
        entries.sort { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            return lhs.name < rhs.name
        }
        albums = entries.compactMap { entry in
            guard let first = entry.songs.first else { return nil }
            return AlbumInfo(name: entry.name, artist: first.artist, artworkData: first.artworkData, songs: entry.songs)
        }
        signature = newSignature
        return albums
    }
}

// Decodes album artwork on a background thread and "bakes" each cover into a
// single finished image (artwork, rounded corners, glass sheen and hairline
// border) so the carousel only has to draw one flat image per cover instead
// of re-compositing a clip mask and two overlays every frame. Effects that
// depend on distance from center (rotation, shadow, saturation, brightness,
// reflection fade) stay live in the view. Results are kept in bounded caches.
enum AlbumArtworkLoader {
    // Decoded thumbnails (cost-limited by pixel bytes); needed only to re-bake
    // when the cover's on-screen size changes.
    private static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    // Finished covers, keyed by artwork + display size bucket.
    private static let coverCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    // Covers render at most ~200pt tall, so 512px is sharp on Retina displays.
    private static let maxPixelSize = 512

    // Cover sizes are bucketed so the baked corner radius/border stay
    // proportionally correct without re-baking on every resize tick.
    private static let sizeBucket: CGFloat = 8

    static func bucketedWidth(_ width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return max(sizeBucket, (width / sizeBucket).rounded() * sizeBucket)
    }

    private static func coverKey(for album: AlbumInfo, displayWidth: CGFloat) -> NSString {
        "\(album.artworkKey)|\(Int(displayWidth))" as NSString
    }

    static func cachedCover(for album: AlbumInfo, displayWidth: CGFloat) -> NSImage? {
        guard displayWidth > 0 else { return nil }
        return coverCache.object(forKey: coverKey(for: album, displayWidth: displayWidth))
    }

    // Returns the baked cover for `album` at `displayWidth` points (the
    // cover's long side), or nil if the album has no decodable artwork.
    static func cover(for album: AlbumInfo, displayWidth: CGFloat) async -> NSImage? {
        guard displayWidth > 0, let data = album.artworkData else { return nil }
        let key = coverKey(for: album, displayWidth: displayWidth)
        if let cached = coverCache.object(forKey: key) { return cached }

        let thumbnailKey = album.artworkKey as NSString
        let cachedThumbnail = thumbnailCache.object(forKey: thumbnailKey)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)

        // Decode (if needed) and bake off the main thread.
        let result = await Task.detached(priority: .userInitiated) { () -> (thumbnail: CGImage, baked: CGImage)? in
            let thumbnail = cachedThumbnail ?? downsample(data: data, maxPixelSize: maxPixelSize)
            guard let thumbnail, let baked = bake(thumbnail, displayWidth: displayWidth) else { return nil }
            return (thumbnail, baked)
        }.value
        guard let result else { return nil }
        let baked = result.baked

        let image = NSImage(cgImage: baked, size: NSSize(width: baked.width, height: baked.height))
        coverCache.setObject(image, forKey: key, cost: baked.width * baked.height * 4)
        if cachedThumbnail == nil {
            // Keep the unbaked thumbnail for later re-bakes (e.g. window resize).
            let thumbnail = result.thumbnail
            let thumbImage = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            thumbnailCache.setObject(thumbImage, forKey: thumbnailKey, cost: thumbnail.width * thumbnail.height * 4)
        }
        return image
    }

    // Uses ImageIO's thumbnail generation to decode directly to the target
    // pixel size, far cheaper than decoding full-size then resizing.
    private static func downsample(data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
    }

    // Draws the finished cover: the artwork clipped to a 3pt rounded rect,
    // then (unclipped, exactly like the former SwiftUI overlay) the top-down
    // glass sheen using additive blending, then a 1pt inside hairline border.
    // Point-based metrics are scaled by pixels-per-point so the result matches
    // the live-composited look at `displayWidth`.
    private static func bake(_ image: CGImage, displayWidth: CGFloat) -> CGImage? {
        let width = image.width
        let height = image.height
        let pixelsPerPoint = CGFloat(max(width, height)) / displayWidth
        let radius = 3 * pixelsPerPoint
        let lineWidth = 1 * pixelsPerPoint
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.interpolationQuality = .high

        // Artwork, clipped to the rounded rect.
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.draw(image, in: rect)
        context.restoreGState()

        // Glass sheen: white 0.28 → 0.06 (18%) → 0 (40%), top to bottom, plusLighter.
        let sheenColors: [CGFloat] = [
            1, 1, 1, 0.28,
            1, 1, 1, 0.06,
            1, 1, 1, 0.0
        ]
        let sheenLocations: [CGFloat] = [0.0, 0.18, 0.4]
        if let gradient = CGGradient(
            colorSpace: colorSpace,
            colorComponents: sheenColors,
            locations: sheenLocations,
            count: 3
        ) {
            context.saveGState()
            context.setBlendMode(.plusLighter)
            // CoreGraphics' origin is bottom-left, so "top" is y = height.
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: CGFloat(height)),
                end: CGPoint(x: 0, y: 0),
                options: []
            )
            context.restoreGState()
        }

        // Hairline border drawn inside the edge (matches `strokeBorder`).
        let inset = lineWidth / 2
        let borderRect = rect.insetBy(dx: inset, dy: inset)
        let borderRadius = max(0, radius - inset)
        context.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.08])!)
        context.setLineWidth(lineWidth)
        context.addPath(CGPath(roundedRect: borderRect, cornerWidth: borderRadius, cornerHeight: borderRadius, transform: nil))
        context.strokePath()

        return context.makeImage()
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
    // Width (points) of the cover area; the baked cover is sized to match.
    let coverWidth: CGFloat

    // Finished (baked) cover image, loaded lazily and asynchronously (nil
    // until ready, or if the album has no artwork).
    @State private var artwork: NSImage?

    init(album: AlbumInfo, index: Int, currentIndex: Int, geometry: GeometryProxy, isInteracting: Bool, coverWidth: CGFloat) {
        self.album = album
        self.index = index
        self.currentIndex = currentIndex
        self.geometry = geometry
        self.isInteracting = isInteracting
        self.coverWidth = coverWidth
        // Seed from the cache so already-baked covers appear immediately.
        let displayWidth = AlbumArtworkLoader.bucketedWidth(coverWidth)
        _artwork = State(initialValue: AlbumArtworkLoader.cachedCover(for: album, displayWidth: displayWidth))
    }

    // Identity of the baked image: re-runs loading when artwork or size bucket changes.
    private var bakeID: String {
        "\(album.artworkKey)|\(Int(AlbumArtworkLoader.bucketedWidth(coverWidth)))"
    }

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
                    perspective: CoverFlowMetrics.perspective
                )

            // Reflection
            // A second copy of the same cover, flipped vertically and faded
            // out via a gradient mask, to simulate a glossy reflective floor.
            // The falloff is steep (most of the reflection has vanished by
            // ~40% of its height) so it reads as a quick glossy sheen rather
            // than a full mirror image — closer items get a brighter, taller
            // reflection than items further from center.
            //
            // The flip and fade happen *before* the 3D rotation, and the
            // rotation uses the same angle as the cover with its pivot/eye
            // level placed at the cover's vertical center (half a cell above
            // the reflection). That way the reflection is foreshortened exactly
            // like the cover and shares the cover's bottom edge, instead of
            // being tilted about its own center (which pulled it away from the
            // cover on the outer side).
            coverImage
                .scaleEffect(x: 1, y: -1) // flip vertically
                .mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.black.opacity(isCenterItem ? 0.5 : 0.22), location: 0.0),
                            .init(color: Color.black.opacity(isCenterItem ? 0.14 : 0.05), location: 0.35),
                            .init(color: Color.black.opacity(0.0), location: 0.7)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .rotation3DEffect(
                    .degrees(rotationAngle),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: reflectionRotationAnchor,
                    perspective: CoverFlowMetrics.perspective
                )
        }
        .saturation(itemSaturation)
        .brightness(itemBrightness)
        .compositingGroup()
        .animation(.easeInOut(duration: 0.3), value: currentIndex)
        .task(id: bakeID) {
            let displayWidth = AlbumArtworkLoader.bucketedWidth(coverWidth)
            guard displayWidth > 0 else { return }
            if let cached = AlbumArtworkLoader.cachedCover(for: album, displayWidth: displayWidth) {
                artwork = cached
            } else {
                artwork = await AlbumArtworkLoader.cover(for: album, displayWidth: displayWidth)
            }
        }
        .focusable(false)
        .buttonStyle(PlainButtonStyle())
    }

    // The actual cover artwork view: the album's artwork image if available,
    // otherwise a generated gradient placeholder with a music-note icon and
    // album name. A subtle top-down glass sheen is layered over the artwork
    // (the "glossy" highlight classic CoverFlow covers had), and shadow
    // intensity/blur increases for the centered item.
    @ViewBuilder
    private var coverImage: some View {
        if let image = artwork {
            // Rounded corners, sheen and border are already baked in.
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .modifier(coverShadow)
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
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(glossOverlay)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .modifier(coverShadow)
        }
    }

    // Drop shadow whose intensity/blur grows for the centered item.
    private var coverShadow: CoverShadow {
        CoverShadow(isCenter: isCenterItem)
    }

    // Soft glass highlight running along the top of the cover, fading out
    // by the upper-third
    private var glossOverlay: some View {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color.white.opacity(0.28), location: 0.0),
                .init(color: Color.white.opacity(0.06), location: 0.18),
                .init(color: Color.white.opacity(0.0), location: 0.4)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
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
        let baseRotation = CoverFlowMetrics.baseRotation
        let extra = min(Double(distanceFromCenter - 1) * 3.0, CoverFlowMetrics.maxExtraRotation)
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

    // Same horizontal pivot as the cover, but vertically at the cover's center,
    // which sits half a cell above the reflection (the reflection is directly
    // below the cover and the same height).
    private var reflectionRotationAnchor: UnitPoint {
        UnitPoint(x: rotationAnchor.x, y: -0.5)
    }
}

// Shadow applied to each cover; stronger and softer for the centered cover.
private struct CoverShadow: ViewModifier {
    let isCenter: Bool

    func body(content: Content) -> some View {
        content.shadow(
            color: .black.opacity(isCenter ? 0.7 : 0.4),
            radius: isCenter ? 14 : 4,
            x: 0,
            y: isCenter ? 6 : 2
        )
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
