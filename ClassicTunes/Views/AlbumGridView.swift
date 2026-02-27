import SwiftUI
import AppKit

struct AlbumGridView: View {
    var songs: [Song]
    var selectedAlbum: String?
    var onAlbumSelect: (String) -> Void
    var onSongSelect: (Song) -> Void = { _ in } // Caller may override; we also provide a default fallback via handleSongSelect(_:)
    @State private var coverSize: CGFloat = 120
    @State private var expandedAlbum: String? = nil

    var body: some View {
        VStack {
            sizeSlider
            albumGrid
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
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
        .padding(.horizontal)
        .padding(.top, 8)
    }
    
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
        }
    }
    
    private func handleSongSelect(_ song: Song) {
        var usedCustomHandler = false
        // Detect if the onSongSelect was customized by comparing against a no-op? We can't reliably compare closures.
        // Always call the provided closure first.
        onSongSelect(song)
        // Also post a notification so a global player can respond by default.
        NotificationCenter.default.post(name: .PlaybackDidRequestSong, object: song)
        // Collapse the expanded album for better UX.
        withAnimation { expandedAlbum = nil }
    }

    private func albumCellWithDetailCollapsedOnly(album: String) -> some View {
        VStack {
            if let artwork = songs.first(where: { $0.album == album })?.url,
               let image = getArtwork(from: artwork) {
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

    private func albumCellWithDetail(album: String) -> some View {
        VStack(spacing: 0) {
            VStack {
                if let artwork = songs.first(where: { $0.album == album })?.url,
                   let image = getArtwork(from: artwork) {
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

struct AlbumDetailView: View {
    let albumName: String
    let songs: [Song]
    let onSongSelect: (Song) -> Void
    
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
                        .fill(Color(nsColor: .underPageBackgroundColor))
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
            
            // Album info and songs
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
                    
                    Text("\(songs.count) songs")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Songs list with vertical scrollbar
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(songs.indices, id: \.self) { index in
                            let song = songs[index]
                            Button(action: { onSongSelect(song) }) {
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
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
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
        )
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

extension Notification.Name {
    static let PlaybackDidRequestSong = Notification.Name("PlaybackDidRequestSong")
}
