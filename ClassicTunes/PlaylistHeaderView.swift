import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Keyed by playlist UUID string. Images are written as JPEG to Application Support.
final class PlaylistArtworkStore {
    static let shared = PlaylistArtworkStore()
    private init() {}

    private let fm = FileManager.default

    private var artworkDir: URL? {
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "ClassicTunes"
        let dir = appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("PlaylistArtwork", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func fileURL(for playlistID: UUID) -> URL? {
        artworkDir?.appendingPathComponent("\(playlistID.uuidString).jpg")
    }

    // Load artwork for a playlist, returns nil if none saved.
    func load(for playlistID: UUID) -> NSImage? {
        guard let url = fileURL(for: playlistID),
              fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    // Persist artwork for a playlist. Pass nil to delete.
    func save(_ image: NSImage?, for playlistID: UUID) {
        guard let url = fileURL(for: playlistID) else { return }
        if let image {
            // Compress as JPEG for smaller storage
            if let tiff = image.tiffRepresentation,
               let bmp = NSBitmapImageRep(data: tiff),
               let jpeg = bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                try? jpeg.write(to: url, options: .atomic)
            }
        } else {
            try? fm.removeItem(at: url)
        }
    }

    // Delete artwork when a playlist is deleted.
    func delete(for playlistID: UUID) {
        guard let url = fileURL(for: playlistID) else { return }
        try? fm.removeItem(at: url)
    }
}

// The iTunes-style header shown at the top.
struct PlaylistHeaderView: View {
    let playlist: Playlist
    let onPlay: () -> Void
    let onShuffle: () -> Void

    @State private var customImage: NSImage? = nil
    @State private var isHoveringArtwork = false
    @Environment(\.colorScheme) private var colorScheme

    // Duration sum derived from parsed metadata (Song.duration)
    private var durationString: String {
        let total = playlist.songs.reduce(0.0) { acc, song in
            let secs = song.duration ?? 0
            return acc + (secs.isNaN || secs.isInfinite ? 0 : secs)
        }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        if hours > 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s"), \(minutes) minute\(minutes == 1 ? "" : "s")"
        } else {
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
    }

    private var songCountString: String {
        let count = playlist.songs.count
        return "\(count) song\(count == 1 ? "" : "s")"
    }

    var body: some View {
        ZStack(alignment: .leading) {

            HStack(spacing: 16) {
                // Artwork square — click to change
                artworkThumbnail()

                // Title + controls + metadata
                VStack(alignment: .leading, spacing: 6) {
                    // Playlist name
                    Text(playlist.name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                        .lineLimit(1)

                    // Play / Shuffle buttons
                    HStack(spacing: 8) {
                        headerButton(systemImage: "play.fill", accessibilityLabel: "playlistHeader.play") {
                            onPlay()
                        }
                        headerButton(systemImage: "shuffle", accessibilityLabel: "playlistHeader.shuffle") {
                            onShuffle()
                        }
                    }

                    // Song count · duration
                    Text("\(songCountString) · \(durationString)")
                        .font(.caption)
                        .foregroundColor(colorScheme == .dark
                                         ? Color.white.opacity(0.65)
                                         : Color.black.opacity(0.55))
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 110)
        .onAppear {
            customImage = PlaylistArtworkStore.shared.load(for: playlist.id)
        }
        .onChange(of: playlist.id) { _ in
            customImage = nil
            customImage = PlaylistArtworkStore.shared.load(for: playlist.id)
        }
    }

    // Artwork thumbnail

    @ViewBuilder
    private func artworkThumbnail() -> some View {
        ZStack {
            Group {
                if let img = customImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // Mosaic of first four song artworks (same as iTunes)
                    mosaicThumbnail()
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 4)

            // Camera overlay on hover
            if isHoveringArtwork {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 80, height: 80)
                Image(systemName: "camera.fill")
                    .foregroundColor(.white)
                    .font(.system(size: 22))
            }
        }
        .frame(width: 80, height: 80)
        .onHover { isHoveringArtwork = $0 }
        .onTapGesture { pickArtwork() }
        .contextMenu {
            Button("artwork.changePhoto") { pickArtwork() }
            if customImage != nil {
                Button("artwork.removeCustomPhoto", role: .destructive) {
                    PlaylistArtworkStore.shared.save(nil, for: playlist.id)
                    customImage = nil
                }
            }
        }
        .help("artwork.help")
    }

    @ViewBuilder
    private func mosaicThumbnail() -> some View {
        let artworks: [NSImage] = playlist.songs
            .prefix(4)
            .compactMap { song in
                guard let data = song.artworkData else { return nil }
                return NSImage(data: data)
            }

        if artworks.isEmpty {
            // Fallback: music note icon
            ZStack {
                Color(nsColor: .quaternaryLabelColor)
                Image(systemName: "music.note.list")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
            }
        } else if artworks.count == 1 {
            Image(nsImage: artworks[0])
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Pad to exactly 4 entries by cycling through what we have
            let padded: [NSImage] = (0..<4).map { artworks[$0 % artworks.count] }
            GeometryReader { geo in
                let half = geo.size.width / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Image(nsImage: padded[0])
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: half, height: half).clipped()
                        Image(nsImage: padded[1])
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: half, height: half).clipped()
                    }
                    HStack(spacing: 0) {
                        Image(nsImage: padded[2])
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: half, height: half).clipped()
                        Image(nsImage: padded[3])
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: half, height: half).clipped()
                    }
                }
            }
        }
    }

    // Header button helper
    @ViewBuilder
    private func headerButton(systemImage: String,
                               accessibilityLabel: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(colorScheme == .dark
                              ? Color.white.opacity(0.15)
                              : Color.black.opacity(0.1))
                )
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    // Photo picker
    private func pickArtwork() {
        let panel = NSOpenPanel()
        panel.title = "artwork.changePhoto"
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff, .bmp, .gif]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let image = NSImage(contentsOf: url) else { return }
            Task { @MainActor in
                PlaylistArtworkStore.shared.save(image, for: playlist.id)
                customImage = image
            }
        }
    }
}

