import SwiftUI

struct CoverFlowView: View {
    let albums: [AlbumInfo]
    @Binding var selectedAlbum: String?
    @Binding var isCoverFlowActive: Bool
    var onAlbumSelect: (String) -> Void

    @State private var currentIndex: Int = 0
    @State private var sliderValue: Double = 0.0

    var body: some View {
        VStack(spacing: 0) {
            // CoverFlow carousel
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.black,
                        Color(red: 0.1, green: 0.1, blue: 0.1),
                        Color.black
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )

                GeometryReader { geometry in
                    ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: -geometry.size.width * 0.10) {
                                ForEach(Array(albums.enumerated()), id: \.offset) { index, album in
                                    CoverFlowItemView(
                                        album: album,
                                        index: index,
                                        currentIndex: currentIndex,
                                        geometry: geometry
                                    )
                                    .frame(width: geometry.size.width * 0.25)
                                    .id(index)
                                    .zIndex(Double(albums.count - abs(index - currentIndex)))
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            currentIndex = index
                                            sliderValue = Double(index)
                                            scrollProxy.scrollTo(index, anchor: .center)
                                            selectAndPlay(album: album)
                                        }
                                    }
                                    .focusable(false)
                                    .buttonStyle(PlainButtonStyle())
                                    .accentColor(.clear)
                                    .border(Color.clear, width: 0)
                                }
                            }
                        }
                        .onAppear {
                            DispatchQueue.main.async {
                                if !albums.isEmpty {
                                    scrollProxy.scrollTo(currentIndex, anchor: .center)
                                }
                                sliderValue = Double(currentIndex)
                            }
                        }
                        .onChange(of: currentIndex) { newValue in
                            if !albums.isEmpty {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    scrollProxy.scrollTo(newValue, anchor: .center)
                                }
                            }
                        }
                        .focusable(false)
                        .buttonStyle(PlainButtonStyle())
                        .accentColor(.clear)
                        .border(Color.clear, width: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())

            // Classic iTunes-style slider for album navigation
            if albums.count > 1 {
                HStack {
                    Text("1")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(width: 24, alignment: .leading)
                    Slider(
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
                        in: 0...Double(albums.count - 1),
                        step: 1,
                        onEditingChanged: { isEditing in
                            if !isEditing {
                                playCurrentAlbum()
                            }
                        }
                    )
                    .accentColor(Color(NSColor.systemBlue))
                    .frame(height: 4)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 0)
                    Text("\(albums.count)")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(width: 24, alignment: .trailing)
                }
                .padding(.horizontal, 40)
                .background(Color.clear)
            }

            // Album info panel
            if !albums.isEmpty && currentIndex < albums.count {
                VStack(alignment: .leading, spacing: 8) {
                    Text(albums[currentIndex].name)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text(albums[currentIndex].artist)
                        .font(.title3)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.black.opacity(0.7))
            }
        }
        .background(Color.black)
        .clipped()
        .clipShape(Rectangle())
        .onChange(of: currentIndex) { newValue in
            if newValue < albums.count {
                selectedAlbum = albums[newValue].name
                sliderValue = Double(newValue)
            }
        }
        .onAppear {
            if let selected = selectedAlbum,
               let index = albums.firstIndex(where: { $0.name == selected }) {
                currentIndex = index
                sliderValue = Double(index)
            } else if !albums.isEmpty {
                currentIndex = 0
                sliderValue = 0.0
            }
        }
        .focusable(false)
        .buttonStyle(PlainButtonStyle())
        .accentColor(.clear)
        .border(Color.clear, width: 0)
    }
    
    private func selectAndPlay(album: AlbumInfo) {
        selectedAlbum = album.name
        onAlbumSelect(album.name)
    }

    private func playCurrentAlbum() {
        guard currentIndex < albums.count else { return }
        let album = albums[currentIndex]
        selectAndPlay(album: album)
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
        self.artwork = artworkData.flatMap { NSImage(data: $0) }
    }
}

struct CoverFlowItemView: View {
    let album: AlbumInfo
    let index: Int
    let currentIndex: Int
    let geometry: GeometryProxy

    var body: some View {
        ZStack {
            if let image = album.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black, radius: isCenterItem ? 8 : 3, x: 0, y: isCenterItem ? 8 : 3)
                    .mask(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white)
                    )
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        gradient: Gradient(colors: [.gray, .black]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay(
                        VStack {
                            Text(album.name)
                                .font(.caption)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                            Text(album.artist)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        .padding(4)
                    )
                    .shadow(color: .black, radius: isCenterItem ? 8 : 3, x: 0, y: isCenterItem ? 8 : 3)
                    .mask(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white)
                    )
            }

            // Reflection (positioned below the main artwork)
            if let image = album.artwork {
                ReflectionView(image: image)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(
                                stops: [
                                    .init(color: .white, location: 0),
                                    .init(color: .white.opacity(0.1), location: 0.2),
                                    .init(color: .clear, location: 1)
                                ]
                            ),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .mask(
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(
                                        stops: [
                                            .init(color: .black, location: 0),
                                            .init(color: .black.opacity(0.3), location: 0.5),
                                            .init(color: .clear, location: 1)
                                        ]
                                    ),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .offset(y: 80)
                    .scaleEffect(x: 1, y: -0.4)
                    .opacity(0.2)
            }
        }
        .scaleEffect(isCenterItem ? 1.1 : 0.85)
        .opacity(1.0)
        .rotation3DEffect(
            .degrees(rotationAngle),
            axis: (x: 0, y: 1, z: 0),
            anchor: rotationAnchor,
            perspective: 0.3
        )
        .animation(.easeInOut(duration: 0.3), value: currentIndex)
        .focusable(false)
        .buttonStyle(PlainButtonStyle())
        .accentColor(.clear)
        .border(Color.clear, width: 0)
        .mask(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white)
        )
    }

    private var isCenterItem: Bool {
        index == currentIndex
    }

    private var rotationAngle: Double {
        guard !isCenterItem else { return 0 }
        let diff = Double(index - currentIndex)
        let maxAngle: Double = 40
        let anglePerItem: Double = 8
        let angle = maxAngle - (abs(diff) - 1) * anglePerItem
        return diff < 0 ? angle : -angle
    }

    private var rotationAnchor: UnitPoint {
        guard !isCenterItem else { return .center }
        let diff = index - currentIndex
        return diff < 0 ? .trailing : .leading
    }
}

struct ReflectionView: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .mask(
                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black.opacity(0.2), location: 0.4),
                                    .init(color: .clear, location: 1)
                                ]
                            ),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .scaleEffect(x: 1, y: -0.4)
            .offset(y: 80)
            .opacity(0.2)
            .blur(radius: 0.5)
    }
}
