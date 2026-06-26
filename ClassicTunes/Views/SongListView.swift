import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Column definition
enum SongColumn: String, CaseIterable, Codable, Identifiable, Hashable {
    case title, artist, album, genre, time, track, disc, year, composer, plays, comment

    var id: String { rawValue }
    
    static let defaultOrder: [SongColumn] = [
        .title, .artist, .album, .genre, .time, .track, .disc, .year, .composer, .plays, .comment
    ]

    static var defaultVisible: [SongColumn] {
        defaultOrder.filter { $0.isVisibleByDefault }
    }

    var isVisibleByDefault: Bool {
        switch self {
        case .title, .artist, .album, .genre: return true
        default: return false
        }
    }

    var canHide: Bool { self != .title }

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

    var localizedTitle: String {
        NSLocalizedString(localizationKey, comment: rawValue)
    }

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

    var isNumeric: Bool {
        switch self {
        case .time, .track, .disc, .plays, .year: return true
        default: return false
        }
    }

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

final class ColumnPreferencesStore: ObservableObject {
    private static let visibleColumnsKey = "songList.visibleColumns.v1"
    private static let widthsKey = "songList.columnWidths.v1"

    @Published private(set) var visibleColumns: [SongColumn]
    private var widths: [SongColumn: CGFloat]

    init() {
        visibleColumns = Self.loadVisibleColumns()
        widths = Self.loadWidths()
    }

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

    private func persistVisibleColumns() {
        let raw = visibleColumns.map { $0.rawValue }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.visibleColumnsKey)
        }
    }

    private func persistWidths() {
        var raw: [String: CGFloat] = [:]
        for (column, fraction) in widths {
            raw[column.rawValue] = fraction
        }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.widthsKey)
        }
    }

    func isVisible(_ column: SongColumn) -> Bool {
        visibleColumns.contains(column)
    }

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

    func resetToDefaults() {
        visibleColumns = SongColumn.defaultVisible
        widths = [:]
        persistVisibleColumns()
        persistWidths()
    }

    func rawWidth(for column: SongColumn) -> CGFloat {
        widths[column] ?? column.defaultFraction
    }

    func setWidths(_ updates: [SongColumn: CGFloat]) {
        for (column, fraction) in updates {
            widths[column] = fraction
        }
        persistWidths()
    }
}

// MARK: - Song list view

struct SongListView: View {
    var isAlbumView: Bool
    var songs: [Song]
    var onSongSelect: (Song) -> Void
    @Binding var selectedSong: Song?
    var onAlbumSelect: (String) -> Void = { _ in }
    var playlistSongs: [Song]?
    var onAddToPlaylist: (Song) -> Void
    @State private var sortBy: SongColumn = .title
    @State private var isAscending = true
    @EnvironmentObject var playlistManager: PlaylistManager

    @StateObject private var columnStore = ColumnPreferencesStore()

    private let minColumnWidth: CGFloat = 50
    private let maxColumnFractionCap: CGFloat = 0.7

    private var sortedSongs: [Song] {
        let songsToSort = playlistSongs ?? songs
        return songsToSort.sorted { lhs, rhs in
            let comparison = sortBy.compare(lhs, rhs)
            return isAscending ? (comparison == .orderedAscending) : (comparison == .orderedDescending)
        }
    }

    private func layoutFractions(rawFractions: [CGFloat], totalWidth: CGFloat) -> [CGFloat] {
        let count = rawFractions.count
        guard count > 0, totalWidth > 0 else { return rawFractions }

        let minF = minColumnWidth / totalWidth
        let maxF = min(maxColumnFractionCap, max(minF, 1 - CGFloat(max(count - 1, 0)) * minF))

        var fractions = rawFractions.map { min(max($0, minF), maxF) }

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

    private func openYouTubeSearch(for song: Song) {
        let query = "\(song.artist) \(song.title) official music video"
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

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
