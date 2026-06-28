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
        (isAppDark || albumGridBackgroundStyle == "dark") ? .dark : .light
    }

    // Evaluates environmental contexts to establish the underlying frame fill color[span_15](start_span)[span_15](end_span).
    private var effectiveBackgroundColor: Color {
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

    var body: some View {
        VStack {
            sizeSlider
            albumGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(effectiveBackgroundColor)
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
                        .fill(Color.accentColor)
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
                        HStack(alignment: .top, spacing: itemSpacing) {
                            ForEach(row, id: \.self) { album in
                                albumCellWithDetailCollapsedOnly(album: album)
                                    .frame(width: containerWidth, alignment: .center)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let expanded = expandedAlbum, row.contains(expanded) {
                            AlbumDetailView(
                                albumName: expanded,
                                songs: songs.filter { $0.album == expanded },
                                backgroundColor: effectiveBackgroundColor,
                                onSongSelect: { song in
                                    handleSongSelect(song)
                                }
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.slide)
                            .animation(.easeInOut(duration: 0.3), value: expandedAlbum)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, itemSpacing)
                .frame(maxWidth: .infinity)
            }
            .background(effectiveBackgroundColor)
        }
    }
    
    // Handles explicit track user selection actions, notifications, and visual list resetting[span_18](start_span)[span_18](end_span).
    private func handleSongSelect(_ song: Song) {
        onSongSelect(song)
        NotificationCenter.default.post(name: .PlaybackDidRequestSong, object: song)
        withAnimation { expandedAlbum = nil }
    }

    // Renders a basic vertical thumbnail cell that handles click interactions to reveal detailed songs[span_19](start_span)[span_19](end_span).
    private func albumCellWithDetailCollapsedOnly(album: String) -> some View {
        VStack {
            if let artworkData = songs.first(where: { $0.album == album })?.artworkData,
               let image = NSImage(data: artworkData) {
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
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
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
                if let artworkData = songs.first(where: { $0.album == album })?.artworkData,
                   let image = NSImage(data: artworkData) {
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
            withAnimation {
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

// An embedded row subview displaying comprehensive track arrays, titles, and stats for a specific album[span_22](start_span)[span_22](end_span).
struct AlbumDetailView: View {
    // The name string describing the focused album item[span_23](start_span)[span_23](end_span).
    let albumName: String
    
    // The array collection representing tracks filtered into this discrete record view[span_24](start_span)[span_24](end_span).
    let songs: [Song]
    
    // The background hue assigned to match parent container configurations[span_25](start_span)[span_25](end_span).
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    
    // Callback action triggered upon selecting an individual child row track entry[span_26](start_span)[span_26](end_span).
    let onSongSelect: (Song) -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearanceManager: AppearanceManager
    
    private var isAppDark: Bool {
        if let forced = appearanceManager.currentColorScheme() {
            return forced == .dark
        } else {
            return colorScheme == .dark
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let artworkData = songs.first?.artworkData,
                   let image = NSImage(data: artworkData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isAppDark ? Color.itunesWindowBG : Color(nsColor: .underPageBackgroundColor))
                        .frame(width: 80, height: 80)
                        .overlay(
                            Image(systemName: "music.note")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30, height: 30)
                                .foregroundColor(.gray)
                        )
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(albumName)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    if let artist = songs.first?.artist {
                        Text(artist)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    
                    Text(String(format: NSLocalizedString("albumDetail.songs", comment: "songsCount"), songs.count))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        let sortedSongs = songs.sorted {
                            let a = $0.trackNumber ?? Int.max
                            let b = $1.trackNumber ?? Int.max
                            return a == b ? $0.title < $1.title : a < b
                        }

                        ForEach(Array(sortedSongs.enumerated()), id: \.offset) { index, song in
                            let displayTrackNumber: Int = {
                                if let track = song.trackNumber, track > 0 {
                                    return track
                                } else {
                                    return index + 1
                                }
                            }()
                            Button(action: { onSongSelect(song) }) {
                                HStack(spacing: 12) {
                                    Text("\(displayTrackNumber)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .frame(width: 20, alignment: .trailing)
                                    
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(song.title)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        
                                        Text(song.artist)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
            }
            
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(backgroundColor)
                .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
        )
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Notification Extensions

extension Notification.Name {
    // Dispatched globally across system notification pipelines whenever a standalone album grid cell requests immediate track playback routing[span_27](start_span)[span_27](end_span).
    static let PlaybackDidRequestSong = Notification.Name("PlaybackDidRequestSong")
}
