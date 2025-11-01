import SwiftUI

struct SongListView: View {
    var isAlbumView: Bool
    var songs: [Song]
    var onSongSelect: (Song) -> Void
    @Binding var selectedSong: Song?
    var onAlbumSelect: (String) -> Void = { _ in }
    var playlistSongs: [Song]?
    var onAddToPlaylist: (Song) -> Void  // New parameter
    @State private var sortBy = "title"
    @EnvironmentObject var playlistManager: PlaylistManager // Access to user playlists

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
                gradient: Gradient(colors: [Color(NSColor(calibratedWhite: 0.96, alpha: 1.0)), Color.white]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .foregroundColor(.black)
    }
    
    private var listView: some View {
        List {
            columnHeaders
            songRows
        }
    }
    
    private var columnHeaders: some View {
        HStack {
            headerButton("Title", sort: "title")
            headerButton("Artist", sort: "artist")
            headerButton("Album", sort: "album")
            headerButton("Year", sort: "year", width: 50)
            headerButton("Genre", sort: "genre", width: 100)
        }
    }
    
    private func headerButton(_ title: String, sort: String, width: CGFloat? = nil) -> some View {
        Text(title)
            .fontWeight(.bold)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .onTapGesture { sortBy = sort }
    }
    
    private var songRows: some View {
        ForEach(sortedSongs) { song in
            songRow(song)
        }
    }
    
    private func songRow(_ song: Song) -> some View {
        HStack {
            Text(song.title).frame(maxWidth: .infinity, alignment: .leading)
            Text(song.artist).frame(maxWidth: .infinity, alignment: .leading)
            Text(song.album).frame(maxWidth: .infinity, alignment: .leading)
            Text(song.genre).frame(width: 100, alignment: .leading)
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
        .contextMenu {
            Button("Add to Playlist") {
                onAddToPlaylist(song)
            }
        }
    }
}
