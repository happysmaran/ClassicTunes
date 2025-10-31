import SwiftUI

struct AlbumGridView: View {
    @Environment(\.colorScheme) var colorScheme
    var songs: [Song]
    var selectedAlbum: String?
    var onAlbumSelect: (String) -> Void
    @State private var coverSize: CGFloat = 120

    private let columns = [
        GridItem(.adaptive(minimum: 140), spacing: 20)
    ]

    var body: some View {
        VStack {
            sizeSlider
            albumGrid
        }
        .background(Color.black)
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
                        .fill(Color(NSColor(calibratedWhite: 0.15, alpha: 1.0)))
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
            LazyVGrid(columns: columns, spacing: 20) {
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
                .foregroundColor(.white)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selectedAlbum == album ? Color.accentColor : Color.clear, lineWidth: 2)
        )
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