import SwiftUI

struct SongListView: View {
    var isAlbumView: Bool
    var songs: [Song]
    var onSongSelect: (Song) -> Void
    @Binding var selectedSong: Song?
    var onAlbumSelect: (String) -> Void = { _ in }
    var playlistSongs: [Song]?
    var onAddToPlaylist: (Song) -> Void
    @State private var sortBy = "title"
    @EnvironmentObject var playlistManager: PlaylistManager

    @State private var titleFraction: CGFloat = 0.33
    @State private var artistFraction: CGFloat = 0.23
    @State private var albumFraction: CGFloat = 0.24
    @State private var genreFraction: CGFloat = 0.20

    private let minColumnWidth: CGFloat = 80
    private let maxColumnFractionCap: CGFloat = 0.7

    private var sortedSongs: [Song] {
        let songsToSort = playlistSongs ?? songs
        switch sortBy {
        case "title":
            return songsToSort.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "artist":
            return songsToSort.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case "album":
            return songsToSort.sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        case "genre":
            return songsToSort.sorted { $0.genre.localizedCaseInsensitiveCompare($1.genre) == .orderedAscending }
        default:
            return songsToSort
        }
    }

    // Ensures all fractions are >= minF and sum to 1.0 by redistributing excess/deficit
    private func normalizeAllFractions(totalWidth: CGFloat) {
        let minF = minColumnWidth / max(totalWidth, 1)
        let maxF = min(maxColumnFractionCap, 1 - 3 * minF) // ensure room for other three at minimums

        // Clamp to min and max
        titleFraction = min(max(titleFraction, minF), maxF)
        artistFraction = min(max(artistFraction, minF), maxF)
        albumFraction = min(max(albumFraction, minF), maxF)
        genreFraction = min(max(genreFraction, minF), maxF)

        var sum = titleFraction + artistFraction + albumFraction + genreFraction
        if sum == 1 { return }

        // If sum > 1, reduce from columns above minF proportionally; if sum < 1, add proportionally
        // Compute available positive space above min for each
        let availTitle = max(0, titleFraction - minF)
        let availArtist = max(0, artistFraction - minF)
        let availAlbum = max(0, albumFraction - minF)
        let availGenre = max(0, genreFraction - minF)
        let totalAvail = availTitle + availArtist + availAlbum + availGenre

        if sum > 1, totalAvail > 0 {
            let excess = sum - 1
            // Reduce proportionally based on availability above min
            titleFraction -= excess * (availTitle / totalAvail)
            artistFraction -= excess * (availArtist / totalAvail)
            albumFraction -= excess * (availAlbum / totalAvail)
            genreFraction -= excess * (availGenre / totalAvail)
        } else if sum < 1 {
            var deficit = 1 - sum
            // Compute remaining capacity to grow before hitting maxF
            var capTitle = max(0, maxF - titleFraction)
            var capArtist = max(0, maxF - artistFraction)
            var capAlbum = max(0, maxF - albumFraction)
            var capGenre = max(0, maxF - genreFraction)
            var totalCap = capTitle + capArtist + capAlbum + capGenre
            // Distribute until deficit is gone or capacity is exhausted
            while deficit > 0.0001 && totalCap > 0 {
                let addTitle = deficit * (capTitle / totalCap)
                let addArtist = deficit * (capArtist / totalCap)
                let addAlbum = deficit * (capAlbum / totalCap)
                let addGenre = deficit * (capGenre / totalCap)
                let newTitle = min(titleFraction + addTitle, maxF)
                let newArtist = min(artistFraction + addArtist, maxF)
                let newAlbum = min(albumFraction + addAlbum, maxF)
                let newGenre = min(genreFraction + addGenre, maxF)
                let newDeficit = deficit - (newTitle - titleFraction) + (newArtist - artistFraction) + (newAlbum - albumFraction) + (newGenre - genreFraction)
                titleFraction = newTitle; artistFraction = newArtist; albumFraction = newAlbum; genreFraction = newGenre
                deficit = newDeficit
                capTitle = max(0, maxF - titleFraction)
                capArtist = max(0, maxF - artistFraction)
                capAlbum = max(0, maxF - albumFraction)
                capGenre = max(0, maxF - genreFraction)
                totalCap = capTitle + capArtist + capAlbum + capGenre
            }
        }

        // Final clamp to min and max and normalize residual into last column
        let minClamp = minColumnWidth / max(totalWidth, 1)
        let maxClamp = min(maxColumnFractionCap, 1 - 3 * minClamp)
        titleFraction = min(max(titleFraction, minClamp), maxClamp)
        artistFraction = min(max(artistFraction, minClamp), maxClamp)
        albumFraction = min(max(albumFraction, minClamp), maxClamp)
        genreFraction = min(max(genreFraction, minClamp), maxClamp)

        sum = titleFraction + artistFraction + albumFraction + genreFraction
        if sum != 1 {
            let residual = 1 - sum
            // Add residual to the column with the most remaining capacity to avoid exceeding max
            let caps: [CGFloat] = [maxClamp - titleFraction, maxClamp - artistFraction, maxClamp - albumFraction, maxClamp - genreFraction]
            if let idx = caps.enumerated().max(by: { $0.element < $1.element })?.offset {
                switch idx {
                case 0: titleFraction += residual
                case 1: artistFraction += residual
                case 2: albumFraction += residual
                default: genreFraction += residual
                }
            } else {
                genreFraction += residual
            }
        }
    }

    private func adjustPairAndNormalize(current: inout CGFloat, next: inout CGFloat, deltaPixels: CGFloat, totalWidth: CGFloat) {
        let minF = minColumnWidth / max(totalWidth, 1)
        let maxF = min(maxColumnFractionCap, 1 - 3 * minF)

        // Convert pixel delta to fraction
        var delta = deltaPixels / max(totalWidth, 1)

        // Compute allowable delta so neither column crosses [minF, maxF]
        let maxIncreaseForCurrent = maxF - current
        let maxDecreaseForCurrent = current - minF
        let maxIncreaseForNext = maxF - next
        let maxDecreaseForNext = next - minF

        if delta > 0 {
            // current grows, next shrinks
            delta = min(delta, maxIncreaseForCurrent)
            delta = min(delta, maxDecreaseForNext)
        } else if delta < 0 {
            // current shrinks, next grows
            let posDelta = -delta
            let clampedPos = min(posDelta, maxDecreaseForCurrent)
            delta = -min(clampedPos, maxIncreaseForNext)
        }

        current += delta
        next -= delta

        // Final cleanup to keep total exactly 1.0
        normalizeAllFractions(totalWidth: totalWidth)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isAlbumView {
                AlbumGridView(
                    songs: playlistSongs ?? songs,
                    selectedAlbum: selectedSong?.album,
                    onAlbumSelect: onAlbumSelect
                )
            } else {
                listView
            }
            Divider()
        }
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color(red: 0.96, green: 0.96, blue: 0.96), Color.white]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .foregroundColor(.black)
        .colorScheme(.light)
    }

    private var listView: some View {
        VStack(spacing: 0) {
            columnHeaders

            List {
                songRows
            }
            .listStyle(.plain)
            .frame(minHeight: 0)
        }
    }

    private var columnHeaders: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let titleWidth = titleFraction * total
            let artistWidth = artistFraction * total
            let albumWidth = albumFraction * total
            let genreWidth = genreFraction * total

            HStack(spacing: 0) {
                ResizableHeader(
                    title: "Title",
                    sort: "title",
                    width: .constant(titleWidth),
                    currentSort: sortBy,
                    onSort: { sortBy = $0 },
                    showsHandle: true,
                    onDrag: { delta in
                        var a = titleFraction
                        var b = artistFraction
                        adjustPairAndNormalize(current: &a, next: &b, deltaPixels: delta, totalWidth: total)
                        titleFraction = a
                        artistFraction = b
                    }
                )

                ResizableHeader(
                    title: "Artist",
                    sort: "artist",
                    width: .constant(artistWidth),
                    currentSort: sortBy,
                    onSort: { sortBy = $0 },
                    showsHandle: true,
                    onDrag: { delta in
                        var a = artistFraction
                        var b = albumFraction
                        adjustPairAndNormalize(current: &a, next: &b, deltaPixels: delta, totalWidth: total)
                        artistFraction = a
                        albumFraction = b
                    }
                )

                ResizableHeader(
                    title: "Album",
                    sort: "album",
                    width: .constant(albumWidth),
                    currentSort: sortBy,
                    onSort: { sortBy = $0 },
                    showsHandle: true,
                    onDrag: { delta in
                        var a = albumFraction
                        var b = genreFraction
                        adjustPairAndNormalize(current: &a, next: &b, deltaPixels: delta, totalWidth: total)
                        albumFraction = a
                        genreFraction = b
                    }
                )

                ResizableHeader(
                    title: "Genre",
                    sort: "genre",
                    width: .constant(genreWidth),
                    currentSort: sortBy,
                    onSort: { sortBy = $0 },
                    showsHandle: true,
                    onDrag: { delta in
                        var a = albumFraction
                        var b = genreFraction
                        // Dragging the right edge increases genre and decreases album when dragging right
                        adjustPairAndNormalize(current: &b, next: &a, deltaPixels: delta, totalWidth: total)
                        albumFraction = a
                        genreFraction = b
                    }
                )
            }
            .padding(.vertical, 4)
            .background(Color.white)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 24 + 8) // header height + vertical padding
    }

    private var songRows: some View {
        ForEach(sortedSongs) { song in
            songRow(song)
        }
    }

    private func songRow(_ song: Song) -> some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let titleW = titleFraction * total
            let artistW = artistFraction * total
            let albumW = albumFraction * total
            let genreW = genreFraction * total

            HStack(spacing: 0) {
                Text(song.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: titleW, alignment: .leading)
                    .padding(.leading, 12)

                Text(song.artist)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: artistW, alignment: .leading)

                Text(song.album)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: albumW, alignment: .leading)

                Text(song.genre)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: genreW, alignment: .leading)
                    .padding(.trailing, 12)
            }
            .font(.system(size: 11))
            .background(
                selectedSong?.id == song.id
                ? Color.blue.opacity(0.3)
                : Color.clear
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedSong = song
                onSongSelect(song)
            }
            .contextMenu {
                Button("Add to Playlist") {
                    onAddToPlaylist(song)
                }
            }
        }
        .frame(height: 16)
    }
}

struct ResizableHeader: View {
    let title: String
    let sort: String
    @Binding var width: CGFloat
    let currentSort: String
    let onSort: (String) -> Void
    var showsHandle: Bool = true
    var onDrag: ((CGFloat) -> Void)? = nil

    @State private var isResizing = false
    private let handleWidth: CGFloat = 6

    var body: some View {
        // The header occupies exactly `width` so the left edge of content stays aligned with rows
        ZStack(alignment: .trailing) {
            // Label area fills the column width and is clipped to avoid overdraw/glitches
            HStack(spacing: 4) {
                Text(title)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if currentSort == sort {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                }
            }
            .padding(.leading, 12)
            .frame(width: max(width - handleWidth, 0), alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onSort(sort) }

            if showsHandle {
                Rectangle()
                    .fill(Color.gray.opacity(isResizing ? 0.5 : 0.3))
                    .frame(width: handleWidth)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isResizing { isResizing = true }
                                onDrag?(value.translation.width)
                            }
                            .onEnded { _ in
                                isResizing = false
                            }
                    )
                    .padding(.trailing, -handleWidth / 2)
                    .overlay(
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: max(handleWidth, 10))
                            .allowsHitTesting(true)
                    )
            }
        }
        .frame(width: width, height: 24, alignment: .leading)
    }
}

