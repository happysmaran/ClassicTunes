import SwiftUI
import AVKit
import AVFoundation
import AppKit
import MediaPlayer
import Combine

// A data transport container mapping out top-level response payloads returned from the iTunes Search API web endpoint[span_3](start_span)[span_3](end_span).
struct iTunesSearchResponse: Codable {
    // The absolute cardinality count describing items contained within the server's return envelope[span_4](start_span)[span_4](end_span).
    let resultCount: Int
    // The structural array matrix holding discrete result item models populated by the response[span_5](start_span)[span_5](end_span).
    let results: [iTunesItem]
}

// A flexible, decodable model representation mapping out unified store entity properties from the iTunes Store catalog[span_6](start_span)[span_6](end_span).
struct iTunesItem: Codable, Identifiable {
    let trackId: Int?
    let collectionId: Int?
    let artistId: Int?
    
    let trackName: String?
    let collectionName: String?
    let artistName: String?
    
    // Categorization label identifying asset types such as "song", "album", "music-video", etc[span_7](start_span)[span_7](end_span).
    let kind: String?
    let trackNumber: Int?
    let trackCount: Int?
    let discNumber: Int?
    let discCount: Int?
    
    // Remote address locator supplying temporary 30-second audio stream segments[span_8](start_span)[span_8](end_span).
    let previewUrl: String?
    let artworkUrl100: String?
    let artworkUrl600: String?
    
    // Direct deeper link context to access assets within Apple's first-party environment applications[span_9](start_span)[span_9](end_span).
    let trackViewUrl: String?
    let collectionViewUrl: String?
    
    let trackPrice: Double?
    let collectionPrice: Double?
    let currency: String?
    
    let primaryGenreName: String?
    let releaseDate: String?
    
    // Evaluates structural identities to establish a unique identification signature for the view layer[span_10](start_span)[span_10](end_span).
    var id: String {
        "\(trackId ?? collectionId ?? artistId ?? 0)_\(trackName ?? "")"
    }
    
    // Inspects resolution definitions to return the largest dimensional asset available[span_11](start_span)[span_11](end_span).
    var bestArtworkURL: String? {
        artworkUrl600 ?? artworkUrl100
    }
    
    // Normalizes descriptive strings depending on underlying media types to display clear view values[span_12](start_span)[span_12](end_span).
    var displayTitle: String {
        if kind == "album" || kind?.contains("album") == true {
            return collectionName ?? trackName ?? "Unknown"
        }
        return trackName ?? collectionName ?? "Unknown"
    }
    
    // Exposes fallback creator tags assigned to the localized record[span_13](start_span)[span_13](end_span).
    var displaySubtitle: String {
        artistName ?? ""
    }
}

// A comprehensive workspace viewport that implements asynchronous network lookups against Apple Store assets[span_14](start_span)[span_14](end_span).
struct iTunesStoreView: View {
    @State private var searchText: String = ""
    @State private var results: [iTunesItem] = []
    @State private var isLoading: Bool = false
    @State private var selectedMedia: String = "music"
    
    // Translatable localized mapping vectors defining query category targets passed down to endpoint query items[span_15](start_span)[span_15](end_span).
    let mediaOptions = [
        (NSLocalizedString("store.media.music", comment: "music"), "music"),
        (NSLocalizedString("store.media.movies", comment: "movies"), "movie"),
        (NSLocalizedString("store.media.tvShows", comment:"tvShows"), "tvShow"),
        (NSLocalizedString("store.media.all", comment: "all"), "all")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Classic iTunes-style header
            HStack {
                Picker("store.media.label", selection: $selectedMedia) {
                    ForEach(mediaOptions, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                
                Spacer()
                
                Text("store.title")
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
                TextField("store.welcome.subtitle", text: $searchText, onCommit: performSearch)
                    .textFieldStyle(.plain)
                    .font(.title3)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
            
            Divider()
            
            if isLoading {
                ProgressView("store.searching")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty && !searchText.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("store.noResults.title")
                        .font(.title2)
                    Text("store.noResults.subtitle")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("store.welcome.title")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text("store.welcome.subtitle")
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
    
    // Assembles an asynchronous HTTP transport worker that dispatches query streams directly to Apple servers[span_16](start_span)[span_16](end_span).
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

// A specialized audio stream singleton engine engineered to buffer, broadcast, and toggle digital preview tracks[span_17](start_span)[span_17](end_span).
final class PreviewAudioPlayer: ObservableObject {
    // Global unified environment access hook matching software instance design structures[span_18](start_span)[span_18](end_span).
    static let shared = PreviewAudioPlayer()
    
    private var player: AVPlayer?
    private var currentlyPlayingURLString: String?

    @Published private var playingURLString: String? = nil

    private init() {}

    // Binds an online streaming source onto hardware playback lines while resetting structural system audio cards[span_19](start_span)[span_19](end_span).
    //
    // - Parameters:
    //   - url: The formatted resource target locator reference targeting binary assets[span_20](start_span)[span_20](end_span).
    //   - urlString: The flat string variant utilized to index state evaluations uniquely[span_21](start_span)[span_21](end_span).
    func play(url: URL, urlString: String) {
        if currentlyPlayingURLString == urlString {
            stop()
            return
        }
        
        player?.pause()

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

        newPlayer.play()
    }

    // Explicitly commands active hardware audio channel lines to hold operations and frees operating system system hooks[span_22](start_span)[span_22](end_span).
    func stop() {
        player?.pause()
        player = nil
        currentlyPlayingURLString = nil
        playingURLString = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    // Evaluates if a specified resource sequence string is currently active within the engine core[span_23](start_span)[span_23](end_span).
    func isPlaying(urlString: String) -> Bool {
        return playingURLString == urlString
    }
}

// A graphical interface component mapping layout cells, text items, artwork items, and buttons for store data[span_24](start_span)[span_24](end_span).
struct StoreItemView: View {
    // The structural information source map containing server metadata[span_25](start_span)[span_25](end_span).
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
            
            Text(item.displayTitle)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            
            Text(item.displaySubtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
            
            if let price = item.trackPrice ?? item.collectionPrice, price > 0 {
                Text("\(item.currency ?? "$")\(price, specifier: "%.2f")")
                    .font(.subheadline)
                    .foregroundColor(.blue)
            } else {
                Text("store.free")
                    .font(.subheadline)
                    .foregroundColor(.green)
            }
            
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
                    Button("store.viewInStore") {
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
    
    // Dispatches state validations to safely mount streaming resources on the audio singleton pipeline[span_26](start_span)[span_26](end_span).
    private func playPreview(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        
        if previewPlayer.isPlaying(urlString: urlString) {
            previewPlayer.stop()
        } else {
            previewPlayer.play(url: url, urlString: urlString)
        }
    }
}
