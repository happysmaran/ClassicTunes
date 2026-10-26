import SwiftUI
import AppKit

// A responsive collection view component that arranges library songs into discrete, resizable album covers[span_2](start_span)[span_2](end_span).
//
// Features an interactive custom size control slider and inline dropdown detailed track disclosures[span_3](start_span)[span_3](end_span).
struct AlbumGridView: View {
    // The comprehensive repository of audio tracks to map into albums[span_4](start_span)[span_4](end_span).
    var songs: [Song]
    
    // The currently active selected album name string, if any[span_5](start_span)[span_5](end_span).
    var selectedAlbum: String?
    
    // Callback closure triggered upon selecting an entire album cell[span_6](start_span)[span_6](end_span).
    var onAlbumSelect: (String) -> Void
    
    // Callback closure passing a single specific track selection back up the view tree[span_7](start_span)[span_7](end_span).
    var onSongSelect: (Song) -> Void = { _ in }
    
    // State variable controlling the uniform side length dimension of album art preview cells[span_8](start_span)[span_8](end_span).
    @State private var coverSize: CGFloat = 120
    
    // Tracking state holding the identifier of the album currently expanded inline to reveal tracks[span_9](start_span)[span_9](end_span).
    @State private var expandedAlbum: String? = nil
    
    // Persistent app setting defining user aesthetic preferences for grid environments[span_10](start_span)[span_10](end_span).
    @AppStorage("albumGridBackgroundStyle") private var albumGridBackgroundStyle: String = "light"
    
    // The system illumination context environment property[span_11](start_span)[span_11](end_span).
    @Environment(\.colorScheme) private var colorScheme
    
    // The application-wide window theme and color preference coordinator[span_12](start_span)[span_12](end_span).
    @EnvironmentObject private var appearanceManager: AppearanceManager

    // Determines if the contextual render pass requires a dark color signature[span_13](start_span)[span_13](end_span).
    private var isAppDark: Bool {
        if let forced = appearanceManager.currentColorScheme() {
            return forced == .dark
        } else {
            return colorScheme == .dark
        }
    }

    // Dictates the target style sheet environment constraints passed downstream[span_14](start_span)[span_14](end_span).
    private var gridColorScheme: ColorScheme {
        if albumGridBackgroundStyle == "custom" {
            return customBackgroundColor.isDark ? .dark : .light
        }
        return (isAppDark || albumGridBackgroundStyle == "dark") ? .dark : .light
    }

    // User-picked fill used when the "custom" style is selected.
    @AppStorage("albumGridCustomColor") private var customColorHex: String = BackgroundTarget.defaultCustomColorHex

    private var customBackgroundColor: Color {
        Color(hex: customColorHex) ?? .gray
    }

    // Evaluates environmental contexts to establish the underlying frame fill color[span_15](start_span)[span_15](end_span).
    private var effectiveBackgroundColor: Color {
        if albumGridBackgroundStyle == "custom" {
            return customBackgroundColor
        }
        if isAppDark {
            return Color.itunesWindowBG
        }
        switch albumGridBackgroundStyle {
        case "dark":
            return Color.itunesWindowBG
        default:
            return Color(nsColor: .windowBackgroundColor)
        }
    }

    // Drawer fill that follows the grid's background setting. nil means the stock dark/light gradient.
    private var drawerBaseColor: Color? {
        albumGridBackgroundStyle == "custom" ? customBackgroundColor : nil
    }

    // Whether the drawer should use dark text on a light panel.
    private var isDrawerLight: Bool {
        switch albumGridBackgroundStyle {
        case "custom": return !customBackgroundColor.isDark
        case "light": return true
        default: return false
        }
    }

    var body: some View {
        VStack {
            sizeSlider
            albumGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                effectiveBackgroundColor
                BackgroundImageLayer(target: .albumGrid)
            }
        }
        .environment(\.colorScheme, gridColorScheme)
    }
    
    // An custom geometric slider tracking drag interactions to alter cell bounds interactively[span_16](start_span)[span_16](end_span).
    private var sizeSlider: some View {
        HStack {
            Spacer()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: .separatorColor).opacity(0.3))
                        .frame(height: 4)

                    Capsule()
                        .fill(.tint)
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
        .frame(height: 26)
        .padding(.horizontal)
        .padding(.top, 8)
    }
    
    // Calculates optimal dynamic rows to distribute albums across fluid geometric columns safely[span_17](start_span)[span_17](end_span).
    private var albumGrid: some View {
        let groupedAlbums = Dictionary(grouping: songs) { $0.album }
        let sortedAlbums = groupedAlbums.keys.sorted { lhs, rhs in
            normalizedSortKey(lhs).localizedCaseInsensitiveCompare(normalizedSortKey(rhs)) == .orderedAscending
        }
        
        return GeometryReader { proxy in
            let availableWidth = proxy.size.width
            let itemWidth = coverSize
            let itemSpacing = max(10, coverSize / 6)
            let minItemContainerWidth = max(100, itemWidth + 20)
            let columns = max(1, Int((availableWidth + itemSpacing) / (minItemContainerWidth + itemSpacing)))
            let containerWidth = (availableWidth - (CGFloat(columns) * itemSpacing)) / CGFloat(columns)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: itemSpacing) {
                    let rows: [[String]] = stride(from: 0, to: sortedAlbums.count, by: columns).map { start in
                        Array(sortedAlbums[start ..< min(start + columns, sortedAlbums.count)])
                    }

                    ForEach(rows.indices, id: \.self) { rowIndex in
                        let row = rows[rowIndex]
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top, spacing: itemSpacing) {
                                ForEach(row, id: \.self) { album in
                                    albumCellWithDetailCollapsedOnly(album: album)
                                        .frame(width: containerWidth, alignment: .center)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Always present (zero-height when closed) so the lazy stack animates
                            // its height in lockstep with the rows below instead of fading out a removed view.
                            DrawerSlot(album: expandedAlbum.flatMap { row.contains($0) ? $0 : nil }) { expanded in
                                AlbumDetailView(
                                    albumName: expanded,
                                    songs: songs.filter { $0.album == expanded },
                                    arrowX: CGFloat(row.firstIndex(of: expanded) ?? 0) * (containerWidth + itemSpacing) + containerWidth / 2,
                                    onSongSelect: { song in
                                        handleSongSelect(song)
                                    },
                                    baseColor: drawerBaseColor,
                                    isLightPanel: isDrawerLight
                                )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, itemSpacing)
                .frame(maxWidth: .infinity)
            }
        }
    }
    
    // Handles explicit track user selection actions, notifications, and visual list resetting[span_18](start_span)[span_18](end_span).
    private func handleSongSelect(_ song: Song) {
        onSongSelect(song)
        NotificationCenter.default.post(name: .PlaybackDidRequestSong, object: song)
        withAnimation(.easeInOut(duration: 0.3)) { expandedAlbum = nil }
    }

    // Renders a basic vertical thumbnail cell that handles click interactions to reveal detailed songs[span_19](start_span)[span_19](end_span).
    private func albumCellWithDetailCollapsedOnly(album: String) -> some View {
        VStack {
            if let image = songs.first(where: { $0.album == album })?.artworkThumbnail(maxPixelSize: 400) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: coverSize, height: coverSize)
                    .cornerRadius(8)
            } else {
                fallbackArtwork
            }

            Text(album)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: coverSize)
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)
        }
        .frame(width: coverSize)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                if expandedAlbum == album {
                    expandedAlbum = nil
                } else {
                    expandedAlbum = album
                }
            }
        }
    }

    // Alternative structure parsing individual component alignment grids[span_20](start_span)[span_20](end_span).
    private func albumCellWithDetail(album: String) -> some View {
        VStack(spacing: 0) {
            VStack {
                if let image = songs.first(where: { $0.album == album })?.artworkThumbnail(maxPixelSize: 400) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: coverSize, height: coverSize)
                        .cornerRadius(8)
                } else {
                    fallbackArtwork
                }
                Text(album)
                    .font(.caption)
                    .frame(maxWidth: coverSize)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.primary)
            }
            .frame(width: coverSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                if expandedAlbum == album {
                    expandedAlbum = nil
                } else {
                    expandedAlbum = album
                }
            }
        }
    }
    
    // The default image symbol placeholder structure rendered when embedded file artwork is completely missing[span_21](start_span)[span_21](end_span).
    private var fallbackArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .underPageBackgroundColor))
                .frame(width: coverSize, height: coverSize)
            Image(systemName: "music.note")
                .resizable()
                .scaledToFit()
                .frame(width: coverSize * 0.5, height: coverSize * 0.5)
                .foregroundColor(.gray)
        }
    }
}

// iTunes 8-style inline drawer: a dark panel with a pointer toward the selected album, artwork and
// album info on the left, and a striped track list on the right.
struct AlbumDetailView: View {
    // The name string describing the focused album item.
    let albumName: String
    
    // The tracks belonging to this album.
    let songs: [Song]
    
    // Horizontal position (in the drawer's coordinate space) of the pointer tip, centered under the selected cover.
    var arrowX: CGFloat = 60
    
    // Callback action triggered upon selecting an individual track row.
    let onSongSelect: (Song) -> Void
    
    // Custom panel color; nil uses the stock dark or light gradient.
    var baseColor: Color? = nil
    
    // True when the panel is light, so text switches to dark shades.
    var isLightPanel: Bool = false
    
    @State private var hoveredSongID: UUID?
    
    // Primary content color that contrasts with the panel.
    private var fg: Color { isLightPanel ? .black : .white }
    
    private var panelGradient: LinearGradient {
        let colors: [Color]
        if let baseColor {
            colors = [baseColor.shaded(0.08), baseColor.shaded(-0.08)]
        } else if isLightPanel {
            colors = [Color(white: 0.97), Color(white: 0.88)]
        } else {
            colors = [Color(white: 0.24), Color(white: 0.14)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
    
    private let arrowHeight: CGFloat = 12
    
    private var sortedSongs: [Song] {
        songs.sorted {
            let a = $0.trackNumber ?? Int.max
            let b = $1.trackNumber ?? Int.max
            return a == b ? $0.title < $1.title : a < b
        }
    }
    
    private var totalDuration: TimeInterval {
        songs.reduce(0) { $0 + ($1.duration ?? 0) }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            albumInfo
            trackList
        }
        .padding(20)
        .padding(.top, arrowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            DrawerShape(arrowX: arrowX, arrowHeight: arrowHeight, cornerRadius: 12)
                .fill(panelGradient)
                .overlay {
                    DrawerShape(arrowX: arrowX, arrowHeight: arrowHeight, cornerRadius: 12)
                        .stroke(fg.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(isLightPanel ? 0.2 : 0.35), radius: 8, x: 0, y: 3)
        }
        .environment(\.colorScheme, isLightPanel ? .light : .dark)
        .padding(.vertical, 4)
    }
    
    // Artwork with title, artist, and summary stats beneath.
    private var albumInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image = songs.first?.artworkThumbnail(maxPixelSize: 400) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(fg.opacity(0.12))
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: 160, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(albumName)
                    .font(.headline)
                    .foregroundStyle(fg)
                    .lineLimit(2)
                
                if let artist = songs.first?.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(fg.opacity(0.7))
                        .lineLimit(1)
                }
                
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(fg.opacity(0.5))
            }
            .frame(width: 160, alignment: .leading)
        }
    }
    
    private var summaryText: String {
        let count = String(format: NSLocalizedString("albumDetail.songs", comment: "songsCount"), songs.count)
        guard totalDuration > 0 else { return count }
        return "\(count), \(Self.formatTime(totalDuration))"
    }
    
    // Striped, hoverable list of tracks.
    private var trackList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                ForEach(Array(sortedSongs.enumerated()), id: \.element.id) { index, song in
                    let displayTrackNumber = (song.trackNumber ?? 0) > 0 ? song.trackNumber! : index + 1
                    let isHovered = hoveredSongID == song.id
                    Button(action: { onSongSelect(song) }) {
                        HStack(spacing: 12) {
                            Text("\(displayTrackNumber)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(isHovered ? .white : fg.opacity(0.5))
                                .frame(width: 28, alignment: .trailing)
                            
                            Text(song.title)
                                .font(.callout)
                                .foregroundStyle(isHovered ? .white : fg)
                                .lineLimit(1)
                            
                            Spacer(minLength: 8)
                            
                            if let duration = song.duration {
                                Text(Self.formatTime(duration))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(isHovered ? .white : fg.opacity(0.5))
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(rowBackground(index: index, isHovered: isHovered))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveredSongID = hovering ? song.id : (hoveredSongID == song.id ? nil : hoveredSongID)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    private func rowBackground(index: Int, isHovered: Bool) -> Color {
        if isHovered { return Color.accentColor.opacity(0.85) }
        return index.isMultiple(of: 2) ? fg.opacity(0.06) : .clear
    }
    
    private static func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// Reveals its content from the top edge downward by growing the container's height, so the
// drawer pushes the rows below it instead of sliding sideways.
private struct DrawerSlot<Content: View>: View {
    // The album expanded within this row, or nil when the drawer should be closed.
    let album: String?
    @ViewBuilder let content: (String) -> Content

    // Retained after closing so the content stays visible while the height animates to zero.
    @State private var shownAlbum: String?

    var body: some View {
        DrawerRevealLayout(progress: album == nil ? 0 : 1) {
            if let shownAlbum {
                content(shownAlbum)
                    .opacity(album == nil ? 0 : 1)
            }
        }
        .clipped()
        .onAppear { shownAlbum = album }
        .onChange(of: album) { _, newValue in
            if let newValue {
                shownAlbum = newValue
            } else {
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if album == nil { shownAlbum = nil }
                }
            }
        }
    }
}

private struct DrawerRevealLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        // Lay out at full size, pinned to the top; the shrinking bounds clip it.
        let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

// A rounded rectangle with an upward-pointing notch along the top edge.
private struct DrawerShape: Shape {
    var arrowX: CGFloat
    var arrowHeight: CGFloat
    var cornerRadius: CGFloat
    
    var animatableData: CGFloat {
        get { arrowX }
        set { arrowX = newValue }
    }
    
    func path(in rect: CGRect) -> Path {
        let r = cornerRadius
        let top = rect.minY + arrowHeight
        // Keep the pointer clear of the rounded corners.
        let tipX = min(max(arrowX, rect.minX + r + arrowHeight), rect.maxX - r - arrowHeight)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: top))
        p.addLine(to: CGPoint(x: tipX - arrowHeight, y: top))
        p.addLine(to: CGPoint(x: tipX, y: rect.minY))
        p.addLine(to: CGPoint(x: tipX + arrowHeight, y: top))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: top))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: top + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: top + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: top + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - Notification Extensions

extension Notification.Name {
    // Dispatched globally across system notification pipelines whenever a standalone album grid cell requests immediate track playback routing[span_27](start_span)[span_27](end_span).
    static let PlaybackDidRequestSong = Notification.Name("PlaybackDidRequestSong")
}
