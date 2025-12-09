import SwiftUI

struct CoverFlowView: View {
    let albums: [AlbumInfo]
    @Binding var selectedAlbum: String?
    @Binding var isCoverFlowActive: Bool
    var onAlbumSelect: (String) -> Void
    var songs: [Song] = [] // Added to display songs for the selected album

    @State private var currentIndex: Int = 0
    @State private var sliderValue: Double = 0.0
    @State private var sortBy = "title"
    @State private var selectedSong: Song? = nil
    @State private var showAllSongs = true // New state to toggle between all songs and album songs

    // Get songs for the currently selected album
    private var albumSongs: [Song] {
        guard !albums.isEmpty && currentIndex < albums.count else { return [] }
        let currentAlbum = albums[currentIndex]
        return songs.filter { $0.album == currentAlbum.name }
    }
    
    // All songs or album songs based on toggle
    private var displayedSongs: [Song] {
        showAllSongs ? songs : albumSongs
    }

    private var sortedSongs: [Song] {
        switch sortBy {
        case "title":
            return displayedSongs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "artist":
            return displayedSongs.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case "album":
            return displayedSongs.sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        case "genre":
            return displayedSongs.sorted { $0.genre.localizedCaseInsensitiveCompare($1.genre) == .orderedAscending }
        default:
            return displayedSongs
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Reduced height for CoverFlow area to make space for the list
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.white,
                        Color(red: 0.9, green: 0.9, blue: 0.9),
                        Color.white
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )

                GeometryReader { geometry in
                    let size = geometry.size
                    let coverWidth = size.width * 0.18
                    let centerX = size.width / 2
                    let coverMargin = coverWidth / 2 + size.width * 0.04
                    let leftEdge = coverMargin
                    let rightEdge = size.width - coverMargin

                    let leftCount = currentIndex
                    let rightCount = albums.count - currentIndex - 1

                    ZStack {
                        ForEach(Array(albums.enumerated()), id: \.offset) { index, album in
                            let isCenter = index == currentIndex
                            let frameWidth = isCenter ? coverWidth * 1.2 : coverWidth

                            let x: CGFloat = {
                                if index < currentIndex {
                                    // Left stack
                                    let distanceFromCenter = currentIndex - index
                                    if leftCount > 0 {
                                        let t = leftCount > 1 ? CGFloat(leftCount - distanceFromCenter) / CGFloat(leftCount - 1) : 0
                                        return leftEdge * (1 - t) + (centerX - coverWidth/2) * t
                                    } else {
                                        return centerX - coverWidth/2
                                    }
                                } else if isCenter {
                                    return centerX
                                } else {
                                    // Right stack
                                    let distanceFromCenter = index - currentIndex
                                    if rightCount > 0 {
                                        let t = rightCount > 1 ? CGFloat(distanceFromCenter - 1) / CGFloat(rightCount - 1) : 0
                                        return (centerX + coverWidth/2) * (1 - t) + rightEdge * t
                                    } else {
                                        return centerX + coverWidth/2
                                    }
                                }
                            }()

                            CoverFlowItemView(
                                album: album,
                                index: index,
                                currentIndex: currentIndex,
                                geometry: geometry
                            )
                            .frame(width: frameWidth, height: frameWidth)
                            .aspectRatio(1, contentMode: .fit)
                            .position(x: x, y: size.height / 2)
                            .zIndex(Double(albums.count) - abs(Double(index - currentIndex)))
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    currentIndex = index
                                    sliderValue = Double(index)
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
            }
            .frame(maxWidth: .infinity, maxHeight: 320) // Reduced height from 480 to 320
            .contentShape(Rectangle())

            if !albums.isEmpty && currentIndex < albums.count {
                VStack(alignment: .center, spacing: 8) {
                    Text(albums[currentIndex].name)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                    Text(albums[currentIndex].artist)
                        .font(.title3)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.7))
            }

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
                    .padding(.vertical, 8)
                    .padding(.horizontal, 0)
                    Text("\(albums.count)")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(width: 24, alignment: .trailing)
                }
                .padding(.horizontal, 40)
                .background(Color.clear)
            }
            
            // iTunes-style list view copied from SongListView.swift
            VStack(spacing: 0) {
                // Column headers with toggle button
                HStack {
                    headerButton("Title", sort: "title")
                    headerButton("Artist", sort: "artist")
                    headerButton("Album", sort: "album")
                    headerButton("Genre", sort: "genre", width: 100)
                    
                    Spacer()
                    
                    // Better positioned toggle button
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
                                .fill(Color.blue.opacity(0.1))
                        )
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 12)
                .background(Color.gray.opacity(0.2))
                
                // Song list
                List {
                    ForEach(sortedSongs) { song in
                        HStack {
                            Text(song.title).frame(maxWidth: .infinity, alignment: .leading)
                            Text(song.artist).frame(maxWidth: .infinity, alignment: .leading)
                            Text(song.album).frame(maxWidth: .infinity, alignment: .leading)
                            Text(song.genre).frame(width: 100, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .background(
                            selectedSong?.id == song.id
                            ? Color.blue.opacity(0.3)
                            : Color.clear
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedSong = song
                            // You might want to trigger playback here
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .listStyle(.plain)
            }
            .frame(maxHeight: .infinity)
            
            Spacer()
        }
        .background(Color.white)
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
    
    private func headerButton(_ title: String, sort: String, width: CGFloat? = nil) -> some View {
        Text(title)
            .fontWeight(.bold)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .onTapGesture { sortBy = sort }
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

    private var isCenterItem: Bool {
        index == currentIndex
    }

    private var distanceFromCenter: Int {
        abs(index - currentIndex)
    }

    var body: some View {
        ZStack {
            if let image = album.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black, radius: isCenterItem ? 8 : 3, x: 0, y: isCenterItem ? 8 : 3)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        gradient: Gradient(colors: [.gray, .white]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay(
                        VStack {
                            Text(album.name)
                                .font(.caption)
                                .foregroundColor(.black)
                                .multilineTextAlignment(.center)
                            Text(album.artist)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        .padding(4)
                    )
                    .shadow(color: .black, radius: isCenterItem ? 8 : 3, x: 0, y: isCenterItem ? 8 : 3)
            }
        }
        .scaleEffect(scaleEffect)
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
    }

    private var scaleEffect: CGFloat {
        guard !isCenterItem else { return 1.2 }
        // Scale decreases as distance from center increases
        let scale = max(0.6, 1.0 - CGFloat(distanceFromCenter) * 0.15)
        return scale
    }

    private var rotationAngle: Double {
        guard !isCenterItem else { return 0 }
        let maxRotation: Double = 45.0
        let rotation = maxRotation * Double(min(distanceFromCenter, 3)) / 3.0
        return Double(index < currentIndex ? rotation : -rotation)
    }

    private var rotationAnchor: UnitPoint {
        guard !isCenterItem else { return .center }
        let diff = index - currentIndex
        return diff < 0 ? .trailing : .leading
    }
}
