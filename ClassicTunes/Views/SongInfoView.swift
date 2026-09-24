import SwiftUI
import AVFoundation
import CoreMedia

// A modal "Get Info" style sheet replicating iTunes' Summary / Info / Lyrics tabs for a track.
//
// Deliberately omits the classic Options tab (volume adjustment, equalizer preset, start/stop
// time, etc.) since those change playback/audio characteristics rather than descriptive metadata.
struct SongInfoView: View {
    let originalSong: Song
    var onSave: (Song) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case summary, info, lyrics
        var id: String { rawValue }
        var titleKey: LocalizedStringKey {
            switch self {
            case .summary: return "songInfo.tab.summary"
            case .info: return "songInfo.tab.info"
            case .lyrics: return "songInfo.tab.lyrics"
            }
        }
    }

    @State private var selectedTab: Tab = .summary

    // Editable Info tab fields, seeded from the song and only applied back on Save.
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var genre: String
    @State private var year: String
    @State private var trackNumber: String
    @State private var discNumber: String
    @State private var composer: String
    @State private var comment: String

    @State private var summary: FileSummary?

    @State private var lyricsText = ""
    @State private var loadedLyrics = ""
    @State private var hasLoadedLyricsOnce = false
    @State private var isLoadingLyrics = false

    @State private var isSaving = false

    init(song: Song, onSave: @escaping (Song) -> Void) {
        self.originalSong = song
        self.onSave = onSave
        _title = State(initialValue: song.title)
        _artist = State(initialValue: song.artist)
        _album = State(initialValue: song.album)
        _genre = State(initialValue: song.genre)
        _year = State(initialValue: song.year ?? "")
        _trackNumber = State(initialValue: song.trackNumber.map(String.init) ?? "")
        _discNumber = State(initialValue: song.discNumber.map(String.init) ?? "")
        _composer = State(initialValue: song.composer ?? "")
        _comment = State(initialValue: song.comment ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.titleKey).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding()

            Divider()

            Group {
                switch selectedTab {
                case .summary: summaryTab
                case .info: infoTab
                case .lyrics: lyricsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
        .frame(width: 480, height: 520)
        .task { await loadSummaryIfNeeded() }
        .onChange(of: selectedTab) { tab in
            if tab == .lyrics {
                Task { await loadLyricsIfNeeded() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if let artwork = originalSong.artworkImage {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? originalSong.title : title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(artist.isEmpty ? originalSong.artist : artist) — \(album.isEmpty ? originalSong.album : album)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Summary tab

    private var summaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let summary {
                    infoRow("songInfo.kind", summary.kind)
                    infoRow("songInfo.size", summary.sizeDescription)
                    infoRow("songInfo.bitRate", summary.bitRateDescription)
                    infoRow("songInfo.sampleRate", summary.sampleRateDescription)
                    infoRow("songInfo.channels", summary.channelsDescription)
                    infoRow("songInfo.dateModified", summary.dateModifiedDescription)
                    infoRow("songInfo.plays", "\(originalSong.playCount)")
                    infoRow("songInfo.lastPlayed", summary.lastPlayedDescription)

                    Divider().padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("songInfo.where")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(originalSong.url.path)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding()
        }
    }

    private func infoRow(_ labelKey: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(labelKey)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }

    // MARK: - Info tab

    private var infoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                labeledField("songInfo.name", text: $title)

                HStack(spacing: 12) {
                    labeledField("songInfo.artist", text: $artist)
                    labeledField("songInfo.year", text: $year)
                }

                labeledField("songInfo.album", text: $album)

                HStack(spacing: 12) {
                    labeledField("songInfo.trackNumber", text: $trackNumber)
                    labeledField("songInfo.discNumber", text: $discNumber)
                }

                labeledField("songInfo.composer", text: $composer)
                labeledField("songInfo.genre", text: $genre)

                VStack(alignment: .leading, spacing: 4) {
                    Text("songInfo.comments")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $comment)
                        .font(.system(size: 12))
                        .frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                }

                if !SongMetadataWriter.canWriteToFile(originalSong.url) {
                    Text("songInfo.unsupportedFormat")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
    }

    private func labeledField(_ labelKey: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(labelKey)
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("", text: text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Lyrics tab

    private var lyricsTab: some View {
        Group {
            if isLoadingLyrics {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $lyricsText)
                    .font(.system(size: 12))
                    .padding(8)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("songInfo.cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("songInfo.save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
        }
        .padding()
    }

    // MARK: - Actions

    private func save() {
        isSaving = true

        var updated = originalSong
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.title = trimmedTitle.isEmpty ? originalSong.title : trimmedTitle
        updated.artist = artist
        updated.album = album
        updated.genre = genre
        updated.year = year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : year
        updated.trackNumber = Int(trackNumber)
        updated.discNumber = Int(discNumber)
        updated.composer = composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : composer
        updated.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : comment

        onSave(updated)
        saveLyricsIfNeeded()

        guard SongMetadataWriter.canWriteToFile(updated.url) else {
            dismiss()
            return
        }

        Task {
            do {
                try await SongMetadataWriter.write(updated, to: updated.url)
            } catch {
                print("Failed to write metadata to \(updated.url.lastPathComponent): \(error)")
            }
            await MainActor.run { dismiss() }
        }
    }

    private func saveLyricsIfNeeded() {
        guard hasLoadedLyricsOnce, lyricsText != loadedLyrics else { return }
        let lrcURL = originalSong.url.deletingPathExtension().appendingPathExtension("lrc")
        try? lyricsText.write(to: lrcURL, atomically: true, encoding: .utf8)
    }

    private func loadSummaryIfNeeded() async {
        guard summary == nil else { return }
        summary = await FileSummary.load(for: originalSong)
    }

    private func loadLyricsIfNeeded() async {
        guard !hasLoadedLyricsOnce else { return }
        hasLoadedLyricsOnce = true
        isLoadingLyrics = true
        defer { isLoadingLyrics = false }

        let lrcURL = originalSong.url.deletingPathExtension().appendingPathExtension("lrc")
        if let fromDisk = try? String(contentsOf: lrcURL, encoding: .utf8) {
            lyricsText = fromDisk
            loadedLyrics = fromDisk
            return
        }

        let asset = AVURLAsset(url: originalSong.url)
        if let embedded = try? await asset.load(.lyrics) {
            lyricsText = embedded
            loadedLyrics = embedded
        }
    }
}

// MARK: - File summary

// Read-only, on-disk statistics for a track — mirrors the top half of iTunes' Summary tab.
private struct FileSummary {
    let kind: String
    let sizeDescription: String
    let bitRateDescription: String
    let sampleRateDescription: String
    let channelsDescription: String
    let dateModifiedDescription: String
    let lastPlayedDescription: String

    static func load(for song: Song) async -> FileSummary {
        let url = song.url
        let asset = AVURLAsset(url: url)

        var bitRateDescription = "—"
        var sampleRateDescription = "—"
        var channelsDescription = "—"

        if let tracks = try? await asset.load(.tracks),
           let track = tracks.first(where: { $0.mediaType == .audio }) {
            if let dataRate = try? await track.load(.estimatedDataRate), dataRate > 0 {
                bitRateDescription = "\(Int((dataRate / 1000).rounded())) kbps"
            }
            if let descriptions = try? await track.load(.formatDescriptions),
               let formatDescription = descriptions.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee {
                sampleRateDescription = "\(Int(asbd.mSampleRate)) Hz"
                switch asbd.mChannelsPerFrame {
                case 1: channelsDescription = "Mono"
                case 2: channelsDescription = "Stereo"
                default: channelsDescription = "\(asbd.mChannelsPerFrame) channels"
                }
            }
        }

        var sizeDescription = "—"
        var dateModifiedDescription = "—"
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let size = (attributes[.size] as? NSNumber)?.int64Value {
                sizeDescription = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
            if let modified = attributes[.modificationDate] as? Date {
                dateModifiedDescription = modified.formatted(date: .numeric, time: .shortened)
            }
        }

        let lastPlayedDescription = getLastPlayed(for: song)?.formatted(date: .numeric, time: .shortened) ?? "—"

        return FileSummary(
            kind: kindDescription(for: url),
            sizeDescription: sizeDescription,
            bitRateDescription: bitRateDescription,
            sampleRateDescription: sampleRateDescription,
            channelsDescription: channelsDescription,
            dateModifiedDescription: dateModifiedDescription,
            lastPlayedDescription: lastPlayedDescription
        )
    }

    private static func kindDescription(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "aac": return "AAC audio file"
        case "mp3": return "MPEG audio file"
        case "wav": return "WAV audio file"
        case "flac": return "FLAC audio file"
        default: return "Audio file"
        }
    }
}
