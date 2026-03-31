import SwiftUI
import AVKit
import AVFoundation
import AppKit
import MediaPlayer
import Combine

struct iTunesSearchResponse: Codable {
    let resultCount: Int
    let results: [iTunesItem]
}

struct iTunesItem: Codable, Identifiable {
    let trackId: Int?
    let collectionId: Int?
    let artistId: Int?
    
    let trackName: String?
    let collectionName: String?
    let artistName: String?
    
    let kind: String? // "song", "album", "music-video", "movie", "tv-episode", etc.
    let trackNumber: Int?
    let trackCount: Int?
    let discNumber: Int?
    let discCount: Int?
    
    let previewUrl: String? // 30-second preview for songs/music videos
    let artworkUrl100: String? // 100x100 artwork
    let artworkUrl600: String? // Sometimes available for larger size
    
    let trackViewUrl: String? // Link to open in native iTunes Store / Music / TV app
    let collectionViewUrl: String?
    
    let trackPrice: Double?
    let collectionPrice: Double?
    let currency: String?
    
    let primaryGenreName: String?
    let releaseDate: String?
    
    // Computed ID for Identifiable
    var id: String {
        "\(trackId ?? collectionId ?? artistId ?? 0)_\(trackName ?? "")"
    }
    
    // Helper to get best artwork URL (prefer larger if available)
    var bestArtworkURL: String? {
        artworkUrl600 ?? artworkUrl100
    }
    
    // Helper to decide what to display as title
    var displayTitle: String {
        if kind == "album" || kind?.contains("album") == true {
            return collectionName ?? trackName ?? "Unknown"
        }
        return trackName ?? collectionName ?? "Unknown"
    }
    
    var displaySubtitle: String {
        artistName ?? ""
    }
}

struct iTunesStoreView: View {
    @State private var searchText: String = ""
    @State private var results: [iTunesItem] = []
    @State private var isLoading: Bool = false
    @State private var selectedMedia: String = "music"  // music, movie, tvShow, etc.
    
    let mediaOptions = [
        ("Music", "music"),
        ("Movies", "movie"),
        ("TV Shows", "tvShow"),
        ("All", "all")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Classic iTunes-style header
            HStack {
                Picker("Media", selection: $selectedMedia) {
                    ForEach(mediaOptions, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                
                Spacer()
                
                Text("iTunes Store")
                    .font(.title2.bold())
                    .foregroundColor(.primary)
                
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search songs, albums, artists, movies...", text: $searchText, onCommit: performSearch)
                    .textFieldStyle(.plain)
                    .font(.title3)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
            
            Divider()
            
            if isLoading {
                ProgressView("Searching iTunes Store...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty && !searchText.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No results found")
                        .font(.title2)
                    Text("Try different keywords or media type")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("Welcome to the iTunes Store")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text("Search for music, albums, movies, and TV shows")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)], spacing: 24) {
                        ForEach(results) { item in
                            StoreItemView(item: item)
                        }
                    }
                    .padding()
                }
            }
        }
        .onChange(of: selectedMedia) { _ in
            if !searchText.isEmpty {
                performSearch()
            }
        }
    }
    
    private func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            return
        }
        
        isLoading = true
        results = []
        
        let term = searchText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let media = selectedMedia == "all" ? "" : "&media=\(selectedMedia)"
        
        let urlString = "https://itunes.apple.com/search?term=\(term)\(media)&limit=50&country=US"
        
        guard let url = URL(string: urlString) else {
            isLoading = false
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false
                
                if let data = data {
                    do {
                        let decoded = try JSONDecoder().decode(iTunesSearchResponse.self, from: data)
                        self.results = decoded.results
                    } catch {
                        print("iTunes Search decode error: \(error)")
                    }
                }
            }
        }.resume()
    }
}

final class PreviewAudioPlayer: ObservableObject {
    static let shared = PreviewAudioPlayer()
    private var player: AVPlayer?
    private var currentlyPlayingURLString: String?

    @Published private var playingURLString: String? = nil

    private init() {}

    func play(url: URL, urlString: String) {
        // If the same URL is playing, stop it
        if currentlyPlayingURLString == urlString {
            stop()
            return
        }
        
        // Stop any existing playback
        player?.pause()

        // Create new player item
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        self.player = newPlayer
        self.currentlyPlayingURLString = urlString
        self.playingURLString = urlString

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "Sample"
        ]
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Start playback
        newPlayer.play()
    }

    func stop() {
        player?.pause()
        player = nil
        currentlyPlayingURLString = nil
        playingURLString = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    func isPlaying(urlString: String) -> Bool {
        return playingURLString == urlString
    }
}

struct StoreItemView: View {
    let item: iTunesItem
    @StateObject private var previewPlayer = PreviewAudioPlayer.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Artwork
            AsyncImage(url: URL(string: item.bestArtworkURL ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: item.kind == "movie" || item.kind?.contains("tv") == true ? "film" : "music.note")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                    )
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 4)
            
            // Title & Subtitle
            Text(item.displayTitle)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            
            Text(item.displaySubtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
            
            // Price or "Free"
            if let price = item.trackPrice ?? item.collectionPrice, price > 0 {
                Text("\(item.currency ?? "$")\(price, specifier: "%.2f")")
                    .font(.subheadline)
                    .foregroundColor(.blue)
            } else {
                Text("Free")
                    .font(.subheadline)
                    .foregroundColor(.green)
            }
            
            // Preview / Buy button
            HStack {
                if let preview = item.previewUrl, (item.kind == "song" || item.kind == "music-video") {
                    Button(action: {
                        playPreview(urlString: preview)
                    }) {
                        Label(previewPlayer.isPlaying(urlString: preview) ? "Stop" : "Preview", 
                              systemImage: previewPlayer.isPlaying(urlString: preview) ? "stop.fill" : "play.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
                
                Spacer()
                
                if let storeURLString = item.trackViewUrl ?? item.collectionViewUrl,
                   let url = URL(string: storeURLString) {
                    Button("View in Store") {
                        // Opens in native Apple apps, if possible
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
    
    private func playPreview(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        
        if previewPlayer.isPlaying(urlString: urlString) {
            previewPlayer.stop()
        } else {
            previewPlayer.play(url: url, urlString: urlString)
        }
    }
}
