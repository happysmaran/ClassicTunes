import SwiftUI

struct AlbumGridView: View {
    // Removed @Environment(\.colorScheme) var colorScheme - this was causing adaptation to system changes
    var songs: [Song]
    var selectedAlbum: String?
    var onAlbumSelect: (String) -> Void
    @State private var coverSize: CGFloat = 120

    var body: some View {
        VStack {
            sizeSlider
            albumGrid
        }
        .background(Color.white)
        .colorScheme(.light) // Force light mode
    }
    
    private var sizeSlider: some View {
        HStack {
            Spacer()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 4)

                    Capsule()
                        .fill(Color.black.opacity(0.85)) // Changed from system-adaptive color to fixed black
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
        
        return ScrollView {
            // Dynamic columns based on current cover size
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: max(100, coverSize + 20)), spacing: max(10, coverSize / 6))
            ], spacing: max(10, coverSize / 6)) {
                ForEach(groupedAlbums.keys.sorted(), id: \.self) { album in
                    albumCell(album: album)
                }
            }
            .padding()
        }
    }
    
    private func albumCell(album: String) -> some View {
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
                .foregroundColor(.black) // Fixed black instead of system color
        }
        .frame(width: coverSize)
        // Removed the stroke that was creating a visible grid line. What the fuck Smaran.
        .onTapGesture {
            onAlbumSelect(album)
        }
    }
    
    private var fallbackArtwork: some View {
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
}
