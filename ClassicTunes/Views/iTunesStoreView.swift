import SwiftUI
import AVKit
import AVFoundation
import AppKit

// A data transport container mapping out top-level response payloads returned from the iTunes Search API web endpoint[span_3](start_span)[span_3](end_span).
struct iTunesSearchResponse: Codable {
    // The absolute cardinality count describing items contained within the server's return envelope[span_4](start_span)[span_4](end_span).
    let resultCount: Int
    // The structural array matrix holding discrete result item models populated by the response[span_5](start_span)[span_5](end_span).
    let results: [iTunesItem]
}

// A flexible, decodable model representation mapping out unified store entity properties from the Tunes Store catalog[span_6](start_span)[span_6](end_span).
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
    // Books report their price under a plain `price` key.
    let price: Double?
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
        (NSLocalizedString("store.media.books", comment: "books"), "ebook"),
        (NSLocalizedString("store.media.all", comment: "all"), "all")
    ]
    
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearanceManager: AppearanceManager

    // Matches the forced app appearance when set, otherwise the system one.
    private var isAppDark: Bool {
        if let forced = appearanceManager.currentColorScheme() {
            return forced == .dark
        }
        return colorScheme == .dark
    }

    private var backgroundColor: Color {
        isAppDark ? Color.itunesWindowBG : Color(nsColor: .windowBackgroundColor)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(backgroundColor)
        .onChange(of: selectedMedia) { _ in
            if !searchText.isEmpty {
                performSearch()
            }
        }
    }

    // Title, media picker and search field grouped into one toolbar-like header.
    private var header: some View {
        VStack(spacing: 12) {
            Text("store.title")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Picker("store.media.label", selection: $selectedMedia) {
                    ForEach(mediaOptions, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 400)

                Spacer()

                TextField("store.welcome.subtitle", text: $searchText, onCommit: performSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("store.searching")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty && !searchText.isEmpty {
            placeholder(symbol: "magnifyingglass", title: "store.noResults.title", subtitle: "store.noResults.subtitle")
        } else if results.isEmpty {
            placeholder(symbol: "music.note.list", title: "store.welcome.title", subtitle: "store.welcome.subtitle")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20, alignment: .top)], spacing: 20) {
                    ForEach(results) { item in
                        StoreItemView(item: item)
                    }
                }
                .padding(20)
            }
        }
    }

    private func placeholder(symbol: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // The iTunes Search API returns nothing for `media=movie`, so movies are found
        // through an unfiltered search and filtered by kind afterwards.
        let isMovieSearch = selectedMedia == "movie"
        let media = (selectedMedia == "all" || isMovieSearch) ? "" : "&media=\(selectedMedia)"
        let limit = isMovieSearch ? 200 : 50
        
        let urlString = "https://itunes.apple.com/search?term=\(term)\(media)&limit=\(limit)&country=US"
        
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
                        self.results = isMovieSearch
                            ? decoded.results.filter { $0.kind == "feature-movie" }
                            : decoded.results
                    } catch {
                        print("iTunes Search decode error: \(error)")
                    }
                }
            }
        }.resume()
    }
}

// A graphical interface component mapping layout cells, text items, artwork items, and buttons for store data[span_24](start_span)[span_24](end_span).
struct StoreItemView: View {
    // The structural information source map containing server metadata[span_25](start_span)[span_25](end_span).
    let item: iTunesItem
    
    @ObservedObject private var engine = PlayerEngine.shared
    
    @State private var isHovering = false

    private var priceText: String? {
        guard let price = item.trackPrice ?? item.collectionPrice ?? item.price, price > 0 else { return nil }
        return "\(item.currency ?? "$")\(String(format: "%.2f", price))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork

            Text(item.displayTitle)
                .font(.headline)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)

            Text(item.displaySubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                if let preview = item.previewUrl, (item.kind == "song" || item.kind == "music-video") {
                    Button(action: { playPreview(urlString: preview) }) {
                        Image(systemName: engine.previewKey == preview ? "stop.fill" : "play.fill")
                            .frame(width: 14)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(engine.previewKey == preview ? "Stop" : "Preview")
                }

                Spacer(minLength: 0)

                if let storeURLString = item.trackViewUrl ?? item.collectionViewUrl,
                   let url = URL(string: storeURLString) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        if let priceText {
                            Text(priceText)
                        } else {
                            Text("store.free")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(Text("store.viewInStore"))
                } else if let priceText {
                    Text(priceText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tint)
                } else {
                    Text("store.free")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isHovering ? 0.22 : 0.1), radius: isHovering ? 8 : 3, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .scaleEffect(isHovering ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var artwork: some View {
        AsyncImage(url: URL(string: item.bestArtworkURL ?? "")) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(Color(nsColor: .underPageBackgroundColor))
                .overlay(
                    Image(systemName: item.kind?.contains("book") == true ? "book" : (item.kind?.contains("movie") == true || item.kind?.contains("tv") == true ? "film" : "music.note"))
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                )
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
    }

    // Starts the preview through the main player, or stops it if it is already the active one.
    private func playPreview(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        
        if engine.previewKey == urlString {
            engine.stopPreview()
        } else {
            engine.playPreview(
                url: url,
                key: urlString,
                title: item.displayTitle,
                artist: item.displaySubtitle,
                album: item.collectionName ?? "",
                genre: item.primaryGenreName ?? "",
                artworkURL: URL(string: item.bestArtworkURL ?? "")
            )
        }
    }
}
