import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Column definition

// A descriptive matrix mapping available metadata column keys to discrete structural spreadsheet entities.
enum SongColumn: String, CaseIterable, Codable, Identifiable, Hashable {
    case title, artist, album, genre, time, track, disc, year, composer, plays, comment

    var id: String { rawValue }
    
    // The canonical fallback ordering scheme mapping columns from left to right.
    static let defaultOrder: [SongColumn] = [
        .title, .artist, .album, .genre, .time, .track, .disc, .year, .composer, .plays, .comment
    ]

    // Resolves the default selection subset flagged for immediate visibility upon new installs.
    static var defaultVisible: [SongColumn] {
        defaultOrder.filter { $0.isVisibleByDefault }
    }

    // Evaluates structural relevance thresholds to verify if a column loads by default.
    var isVisibleByDefault: Bool {
        switch self {
        case .title, .artist, .album, .genre: return true
        default: return false
        }
    }

    // Primary lock preventing critical keys from being toggled off by users.
    var canHide: Bool { self != .title }

    // The string identifier key matching backend dictionary catalog structures.
    var localizationKey: String {
        switch self {
        case .title: return "column.title"
        case .artist: return "column.artist"
        case .album: return "column.album"
        case .genre: return "column.genre"
        case .time: return "column.time"
        case .track: return "column.track"
        case .disc: return "column.disc"
        case .year: return "column.year"
        case .composer: return "column.composer"
        case .plays: return "column.plays"
        case .comment: return "column.comment"
        }
    }

    // Resolves structural lookup symbols to produce clean, localized display title words.
    var localizedTitle: String {
        NSLocalizedString(localizationKey, comment: rawValue)
    }

    // The base percentage share of table width allocated to a column prior to user resizing.
    var defaultFraction: CGFloat {
        switch self {
        case .title: return 0.26
        case .artist: return 0.18
        case .album: return 0.20
        case .genre: return 0.12
        case .time: return 0.06
        case .track: return 0.05
        case .disc: return 0.05
        case .year: return 0.06
        case .composer: return 0.14
        case .plays: return 0.06
        case .comment: return 0.14
        }
    }

    // Tracks whether data values align right (numeric) or left (textual).
    var isNumeric: Bool {
        switch self {
        case .time, .track, .disc, .plays, .year: return true
        default: return false
        }
    }

    // Unboxes data components from a song instance and formats them into display-ready strings.
    //
    // - Parameter song: The underlying track data structure to query.
    // - Returns: A formatted textual representation of the property value.
    func displayValue(for song: Song) -> String {
        switch self {
        case .title: return song.title
        case .artist: return song.artist
        case .album: return song.album
        case .genre: return song.genre
        case .composer: return song.composer ?? ""
        case .comment: return song.comment ?? ""
        case .year: return song.year ?? ""
        case .track:
            guard let t = song.trackNumber else { return "" }
            return "\(t)"
        case .disc:
            guard let d = song.discNumber else { return "" }
            return "\(d)"
        case .plays:
            return song.playCount > 0 ? "\(song.playCount)" : ""
        case .time:
            guard let duration = song.duration, duration.isFinite, duration >= 0 else { return "" }
            let total = Int(duration.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
    }

    // Orchestrates comparison logic between two songs to drive active column sorting.
    //
    // - Parameters:
    //   - lhs: The baseline song structure to evaluate.
    //   - rhs: The comparison song structure to evaluate against.
    // - Returns: A standard comparison result token.
    func compare(_ lhs: Song, _ rhs: Song) -> ComparisonResult {
        switch self {
        case .title:
            return normalizedSortKey(lhs.title).localizedCaseInsensitiveCompare(normalizedSortKey(rhs.title))
        case .artist:
            return normalizedSortKey(lhs.artist).localizedCaseInsensitiveCompare(normalizedSortKey(rhs.artist))
        case .album:
            return normalizedSortKey(lhs.album).localizedCaseInsensitiveCompare(normalizedSortKey(rhs.album))
        case .genre:
            return normalizedSortKey(lhs.genre).localizedCaseInsensitiveCompare(normalizedSortKey(rhs.genre))
        case .composer:
            return normalizedSortKey(lhs.composer ?? "").localizedCaseInsensitiveCompare(normalizedSortKey(rhs.composer ?? ""))
        case .comment:
            return normalizedSortKey(lhs.comment ?? "").localizedCaseInsensitiveCompare(normalizedSortKey(rhs.comment ?? ""))
        case .year:
            return SongColumn.compareNumeric(Int(lhs.year ?? ""), Int(rhs.year ?? ""))
        case .track:
            return SongColumn.compareNumeric(lhs.trackNumber, rhs.trackNumber)
        case .disc:
            return SongColumn.compareNumeric(lhs.discNumber, rhs.discNumber)
        case .plays:
            return SongColumn.compareNumeric(lhs.playCount, rhs.playCount)
        case .time:
            return SongColumn.compareNumeric(lhs.duration, rhs.duration)
        }
    }

    // Compares optional, unboxed sequential types to keep nil values accurately at the bottom of indices.
    private static func compareNumeric<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (l?, r?):
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
            return .orderedSame
        }
    }
}

// MARK: - Persisted column preferences

// A local storage model managing visibility toggles and individual cell widths inside long-term registries.
final class ColumnPreferencesStore: ObservableObject {
    private static let visibleColumnsKey = "songList.visibleColumns.v1"
    private static let widthsKey = "songList.columnWidths.v1"

    // The active array collection representing columns flagged to populate spreadsheet frames.
    @Published private(set) var visibleColumns: [SongColumn]
    private var widths: [SongColumn: CGFloat]

    // Initializes a preferences store and loads saved visibility layouts and custom cell sizes.
    init() {
        visibleColumns = Self.loadVisibleColumns()
        widths = Self.loadWidths()
    }

    // Pulls saved visibility states from persistent storage arrays.
    private static func loadVisibleColumns() -> [SongColumn] {
        guard
            let data = UserDefaults.standard.data(forKey: visibleColumnsKey),
            let raw = try? JSONDecoder().decode([String].self, from: data)
        else {
            return SongColumn.defaultVisible
        }
        let decoded = Set(raw.compactMap { SongColumn(rawValue: $0) })
        return SongColumn.defaultOrder.filter { decoded.contains($0) || $0 == .title }
    }

    // Pulls custom-stretched column fractions from persistent preferences.
    private static func loadWidths() -> [SongColumn: CGFloat] {
        guard
            let data = UserDefaults.standard.data(forKey: widthsKey),
            let raw = try? JSONDecoder().decode([String: CGFloat].self, from: data)
        else {
            return [:]
        }
        var result: [SongColumn: CGFloat] = [:]
        for (key, value) in raw {
            if let column = SongColumn(rawValue: key) {
                result[column] = value
            }
        }
        return result
    }

    // Commits visible column definitions to system preferences.
    private func persistVisibleColumns() {
        let raw = visibleColumns.map { $0.rawValue }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.visibleColumnsKey)
        }
    }

    // Commits tracking column dimension configurations to system preferences.
    private func persistWidths() {
        var raw: [String: CGFloat] = [:]
        for (column, fraction) in widths {
            raw[column.rawValue] = fraction
        }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.widthsKey)
        }
    }

    // Checks if a specified column is flagged for inclusion inside table view structures.
    func isVisible(_ column: SongColumn) -> Bool {
        visibleColumns.contains(column)
    }

    // Inverts visibility metrics for a specified column, saving updates to system preferences.
    func toggle(_ column: SongColumn) {
        guard column.canHide else { return }
        if visibleColumns.contains(column) {
            visibleColumns.removeAll { $0 == column }
        } else {
            let updated = Set(visibleColumns + [column])
            visibleColumns = SongColumn.defaultOrder.filter { updated.contains($0) }
        }
        persistVisibleColumns()
    }

    // Clears preference data stores, resetting widths and visibility metrics back to shipping benchmarks.
    func resetToDefaults() {
        visibleColumns = SongColumn.defaultVisible
        widths = [:]
        persistVisibleColumns()
        persistWidths()
    }

    // Resolves custom track width metrics or falls back to standard enum fraction indices.
    func rawWidth(for column: SongColumn) -> CGFloat {
        widths[column] ?? column.defaultFraction
    }

    // Overwrites width layout definitions and commits changes to persistent system files.
    func setWidths(_ updates: [SongColumn: CGFloat]) {
        for (column, fraction) in updates {
            widths[column] = fraction
        }
        persistWidths()
    }
}

// MARK: - Song list view

// A desktop database view displaying music libraries as an interactive, multi-column grid list.
struct SongListView: View {
    // Toggle controlling whether this layout displays structured cover grids or spreadsheet files.
    var isAlbumView: Bool
    
    // The global music library source track repository map.
    var songs: [Song]
    
    // Callback action triggered to map active music streaming vectors on song selections.
    var onSongSelect: (Song) -> Void
    
    // Two-way binding identifying the currently highlighted focus item inside rows.
    @Binding var selectedSong: Song?
    
    // Explicit routing handler triggered on selection drops inside cover-grid views.
    var onAlbumSelect: (String) -> Void = { _ in }
    
    // Optional context track selection array representing a filtered list or folder collection.
    var playlistSongs: [Song]?
    
    // Closure hook running modifications to add tracks into secondary user lists.
    var onAddToPlaylist: (Song) -> Void
    
    @State private var sortBy: SongColumn = .title
    @State private var isAscending = true
    @EnvironmentObject var playlistManager: PlaylistManager

    @StateObject private var columnStore = ColumnPreferencesStore()

    private let minColumnWidth: CGFloat = 50
    private let maxColumnFractionCap: CGFloat = 0.7

    // Computes and returns sorted track models matching active filter states and key column signatures.
    private var sortedSongs: [Song] {
        let songsToSort = playlistSongs ?? songs
        return songsToSort.sorted { lhs, rhs in
            let comparison = sortBy.compare(lhs, rhs)
            return isAscending ? (comparison == .orderedAscending) : (comparison == .orderedDescending)
        }
    }

    // A normalization layout pass that scales column fractions to sum exactly to 1.0 within bounding constraints.
    private func layoutFractions(rawFractions: [CGFloat], totalWidth: CGFloat) -> [CGFloat] {
        let count = rawFractions.count
        guard count > 0, totalWidth > 0 else { return rawFractions }

        let minF = minColumnWidth / totalWidth
        let maxF = min(maxColumnFractionCap, max(minF, 1 - CGFloat(max(count - 1, 0)) * minF))

        var fractions = rawFractions.map { min(max($0, minF), maxF) }

        // Iteratively balance proportional shares to distribute excess or deficit
        for _ in 0..<6 {
            let sum = fractions.reduce(0, +)
            if abs(sum - 1) < 0.0005 { break }

            if sum > 1 {
                let excess = sum - 1
                let avail = fractions.map { max(0, $0 - minF) }
                let totalAvail = avail.reduce(0, +)
                guard totalAvail > 0 else { break }
                for i in fractions.indices {
                    fractions[i] -= excess * (avail[i] / totalAvail)
                }
            } else {
                let deficit = 1 - sum
                let cap = fractions.map { max(0, maxF - $0) }
                let totalCap = cap.reduce(0, +)
                guard totalCap > 0 else { break }
                for i in fractions.indices {
                    fractions[i] += deficit * (cap[i] / totalCap)
                }
            }
            fractions = fractions.map { min(max($0, minF), maxF) }
        }

        let sum = fractions.reduce(0, +)
        if abs(sum - 1) > 0.0001, let idx = fractions.indices.max(by: { (maxF - fractions[$0]) < (maxF - fractions[$1]) }) {
            fractions[idx] = min(max(fractions[idx] + (1 - sum), minF), maxF)
        }
        return fractions
    }

    // Adjusts column widths based on drag handles, borrowing space from neighboring columns.
    private func adjustBoundary(columns: [SongColumn], currentFractions: [CGFloat], currentIndex: Int, nextIndex: Int, deltaPixels: CGFloat, totalWidth: CGFloat) {
        guard totalWidth > 0,
              currentFractions.indices.contains(currentIndex),
              currentFractions.indices.contains(nextIndex) else { return }

        let minF = minColumnWidth / totalWidth
        let maxF = min(maxColumnFractionCap, max(minF, 1 - CGFloat(max(columns.count - 1, 0)) * minF))

        var current = currentFractions[currentIndex]
        var next = currentFractions[nextIndex]
        var delta = deltaPixels / totalWidth

        if delta > 0 {
            delta = min(delta, maxF - current)
            delta = min(delta, next - minF)
        } else if delta < 0 {
            let positive = -delta
            let clamped = min(positive, current - minF)
            delta = -min(clamped, maxF - next)
        }

        current += delta
        next -= delta

        var updatedFractions = currentFractions
        updatedFractions[currentIndex] = current
        updatedFractions[nextIndex] = next
        updatedFractions = layoutFractions(rawFractions: updatedFractions, totalWidth: totalWidth)

        var updates: [SongColumn: CGFloat] = [:]
        for (column, fraction) in zip(columns, updatedFractions) {
            updates[column] = fraction
        }
        columnStore.setWidths(updates)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isAlbumView {
                AlbumGridView(
                    songs: playlistSongs ?? songs,
                    selectedAlbum: selectedSong?.album,
                    onAlbumSelect: onAlbumSelect,
                    onSongSelect: onSongSelect
                )
            } else {
                listView
            }
            Divider()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // Assembles an explicit search query and dispatches an NSWorkspace event to open a YouTube search in the default web browser.
    private func openYouTubeSearch(for song: Song) {
        let query = "\(song.artist) \(song.title) official music video"
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    // Renders the multi-column song table inside a horizontal scroll view.
    private var listView: some View {
        let columns = columnStore.visibleColumns

        return GeometryReader { proxy in
            let availableWidth = proxy.size.width
            
            let minWidthPerColumn: CGFloat = 85
            let totalMinWidth = CGFloat(columns.count) * minWidthPerColumn
            let tableWidth = max(availableWidth, totalMinWidth)

            let fractions = layoutFractions(
                rawFractions: columns.map { columnStore.rawWidth(for: $0) },
                totalWidth: tableWidth
            )
            let widths = fractions.map { $0 * tableWidth }

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    columnHeaders(columns: columns, widths: widths, fractions: fractions, totalWidth: tableWidth)

                    List {
                        ForEach(sortedSongs) { song in
                            songRow(song, columns: columns, widths: widths)
                        }
                    }
                    .listStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .frame(width: tableWidth)
                    .frame(maxHeight: .infinity)
                }
                .frame(width: tableWidth)
                .frame(maxHeight: .infinity)
            }
        }
    }

    // Generates the header row, providing a context menu to toggle column visibility.
    private func columnHeaders(columns: [SongColumn], widths: [CGFloat], fractions: [CGFloat], totalWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element) { index, column in
                ResizableHeader(
                    title: column.localizedTitle,
                    sort: column,
                    width: .constant(widths[index]),
                    currentSort: sortBy,
                    isAscending: isAscending,
                    alignTrailing: column.isNumeric,
                    isLast: index == columns.count - 1,
                    onSort: { key in
                        if sortBy == key { isAscending.toggle() } else { sortBy = key; isAscending = true }
                    },
                    showsHandle: columns.count > 1,
                    onDrag: { delta in
                        if index == columns.count - 1 {
                            adjustBoundary(columns: columns, currentFractions: fractions, currentIndex: index, nextIndex: index - 1, deltaPixels: delta, totalWidth: totalWidth)
                        } else {
                            adjustBoundary(columns: columns, currentFractions: fractions, currentIndex: index, nextIndex: index + 1, deltaPixels: delta, totalWidth: totalWidth)
                        }
                    }
                )
            }
        }
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .frame(width: totalWidth, height: 32, alignment: .leading)
        .contextMenu {
            columnVisibilityMenu
        }
    }

    // Renders contextual options inside headers to show or hide target columns.
    @ViewBuilder
    private var columnVisibilityMenu: some View {
        ForEach(SongColumn.defaultOrder.filter { $0.canHide }) { column in
            Toggle(isOn: Binding(
                get: { columnStore.isVisible(column) },
                set: { _ in columnStore.toggle(column) }
            )) {
                Text(column.localizedTitle)
            }
        }
        Divider()
        Button(NSLocalizedString("contextMenu.resetColumns", comment: "Reset Columns")) {
            columnStore.resetToDefaults()
        }
    }

    // Maps song items into tabular row objects that register tap actions, context selections, and item drag data.
    private func songRow(_ song: Song, columns: [SongColumn], widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element) { index, column in
                Text(column.displayValue(for: song))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, index == 0 ? 12 : (column.isNumeric ? 0 : 6))
                    .padding(.trailing, index == columns.count - 1 ? 12 : (column.isNumeric ? 6 : 0))
                    .frame(width: widths[index], alignment: column.isNumeric ? .trailing : .leading)
            }
        }
        .font(.system(size: 11))
        .background(
            selectedSong?.id == song.id
            ? Color.accentColor.opacity(0.25)
            : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedSong = song
            onSongSelect(song)
        }
        .contextMenu {
            Button("contextMenu.playNext") {
                NotificationCenter.default.post(name: Notification.Name("AddToUpNextPlayNext"), object: song)
            }
            Button("contextMenu.addToPlaylist") {
                onAddToPlaylist(song)
            }
            Button("contextMenu.findMusicVideo") {
                openYouTubeSearch(for: song)
            }
        }
        .onDrag {
            if let data = try? JSONEncoder().encode(song) {
                return NSItemProvider(item: data as NSData, typeIdentifier: UTType.json.identifier)
            }
            return NSItemProvider()
        }
        .frame(height: 16)
    }
}

// An interactive divider component that updates column widths based on drag gesture offsets.
struct ResizableHeader: View {
    let title: String
    let sort: SongColumn
    @Binding var width: CGFloat
    let currentSort: SongColumn
    let isAscending: Bool
    var alignTrailing: Bool = false
    var isLast: Bool = false
    let onSort: (SongColumn) -> Void
    var showsHandle: Bool = true
    var onDrag: ((CGFloat) -> Void)? = nil

    @State private var isResizing = false
    private let handleWidth: CGFloat = 6

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 4) {
                if alignTrailing { Spacer(minLength: 0) }

                Text(title)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if currentSort == sort {
                    Image(systemName: isAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                }

                if !alignTrailing { Spacer(minLength: 0) }
            }
            .padding(.leading, alignTrailing ? 6 : 12)
            .padding(.trailing, isLast ? 12 : (alignTrailing ? 6 : 0))
            .frame(width: max(width - handleWidth, 0), alignment: alignTrailing ? .trailing : .leading)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onSort(sort) }

            if showsHandle {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(isResizing ? 0.6 : 0.35))
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
        .frame(width: width, height: 24, alignment: alignTrailing ? .trailing : .leading)
        .background(Color.clear)
    }
}
