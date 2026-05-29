import SwiftUI
import AppKit

// MARK: - Root iPod Panel
// Drop this into ContentView when connectedDevice != nil.

struct iPodDeviceView: View {
    let device: iPodDevice
    @ObservedObject var syncEngine: iPodSyncEngine
    var allLibrarySongs: [Song]                         // Full library to pick from

    @State private var deviceTracks:   [iTunesSDTrack] = []
    @State private var selectedSongs:  Set<UUID>       = []
    @State private var showSongPicker  = false
    @State private var showEjectAlert  = false
    @State private var loadError:      String?         = nil
    @State private var showSyncConfirm = false

    // Songs the user has chosen to sync (persisted in-view for the session)
    @State private var syncList: [Song] = []

    @Environment(\.colorScheme) private var colorScheme

    // MARK: Computed

    private var usedBytes: Int64 {
        device.capacity - device.freeSpace
    }
    private var usedFraction: Double {
        guard device.capacity > 0 else { return 0 }
        return Double(usedBytes) / Double(device.capacity)
    }
    private var capacityString: String { formatBytes(device.capacity) }
    private var freeString:     String { formatBytes(device.freeSpace) }
    private var usedString:     String { formatBytes(usedBytes) }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            deviceHeader
            Divider()
            contentArea
            Divider()
            storageBar
            Divider()
            actionBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: loadDeviceTracks)
        .sheet(isPresented: $showSongPicker) {
            SongPickerSheet(
                allSongs: allLibrarySongs,
                alreadySelected: syncList,
                onConfirm: { chosen in
                    // Merge without duplicates
                    let existing = Set(syncList.map { $0.id })
                    let toAdd    = chosen.filter { !existing.contains($0.id) }
                    syncList.append(contentsOf: toAdd)
                }
            )
        }
        .alert("eject.confirm.title", isPresented: $showEjectAlert) {
            Button("eject.eject", role: .destructive) { doEject() }
            Button("eject.cancel", role: .cancel) { }
        } message: {
            Text("eject.confirm.message")
        }
        .alert("sync.confirm.title", isPresented: $showSyncConfirm) {
            Button("sync.sync", role: .destructive) { doSync() }
            Button("sync.cancel", role: .cancel) { }
        } message: {
            Text(String(format: NSLocalizedString("sync.confirm.message", comment: "syncConfirm"), syncList.count))
        }
        .overlay(syncOverlay)
    }

    // MARK: Header

    private var deviceHeader: some View {
        HStack(spacing: 16) {
            // iPod Shuffle icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.9), Color(nsColor: .lightGray)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .shadow(radius: 3)
                Image(systemName: "ipodshuffle")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.primary.opacity(0.7))
                    .padding(10)
            }
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.volumeName)
                    .font(.title2.bold())
                    .foregroundColor(.primary)

                Text(device.generation.rawValue)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("\(capacityString) · \(freeString) available")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Eject button — top-right, like iTunes
            Button(action: { showEjectAlert = true }) {
                Label("device.eject", systemImage: "eject.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("device.eject")
        }
        .padding()
        .background(headerBackground)
    }

    private var headerBackground: some View {
        colorScheme == .dark
            ? AnyView(Color(nsColor: .controlBackgroundColor))
            : AnyView(LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor)],
                startPoint: .top, endPoint: .bottom
            ))
    }

    // MARK: Content (two-column: sync list + device tracks)

    private var contentArea: some View {
        HStack(spacing: 0) {
            // Left: songs queued to sync
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(title: "Music to Sync", count: syncList.count) {
                    Button(action: { showSongPicker = true }) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("sync.addSongs")
                }
                Divider()
                if syncList.isEmpty {
                    emptyDropTarget
                } else {
                    syncListTable
                }
            }
            .frame(maxWidth: .infinity)

            Divider()

            // Right: what's currently on the device
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(title: "On iPod", count: deviceTracks.count) {
                    EmptyView()
                }
                Divider()
                if deviceTracks.isEmpty {
                    Text("device.empty")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    deviceTrackList
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Sync list (left panel)

    private var emptyDropTarget: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("sync.dragHere")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("sync.addSongs") { showSongPicker = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var syncListTable: some View {
        List(selection: $selectedSongs) {
            ForEach(syncList) { song in
                SyncSongRow(song: song, onRemove: {
                    syncList.removeAll { $0.id == song.id }
                })
                .tag(song.id)
            }
            .onMove { from, to in
                syncList.move(fromOffsets: from, toOffset: to)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: Device track list (right panel)

    private var deviceTrackList: some View {
        List {
            ForEach(Array(deviceTracks.enumerated()), id: \.offset) { index, track in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 24, alignment: .trailing)

                    // Show the filename since we don't have full metadata from iTunesSD
                    Text((track.filePath as NSString).lastPathComponent)
                        .font(.body)
                        .lineLimit(1)

                    Spacer()

                    // Remove from device button
                    Button(action: {
                        Task { try? await syncEngine.removeTrack(at: index, from: device) }
                        deviceTracks.remove(at: index)
                    }) {
                        Image(systemName: "minus.circle")
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: Storage bar (iTunes-style coloured breakdown)

    private var storageBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Coloured bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .separatorColor).opacity(0.3))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [Color.iTunesBlue.opacity(0.9), Color.iTunesBlue],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(min(usedFraction, 1.0)))
                }
            }
            .frame(height: 12)

            // Legend
            HStack(spacing: 16) {
                storageLabel(color: .iTunesBlue, text: "Music: \(usedString)")
                Spacer()
                storageLabel(color: Color(nsColor: .separatorColor), text: "Free: \(freeString)")
                storageLabel(color: .primary.opacity(0.4), text: "Total: \(capacityString)")
            }
            .font(.caption2)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func storageLabel(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack {
            Text(String(format: NSLocalizedString("device.trackCount", comment: "trackCount"), deviceTracks.count))
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Button("sync.cancel") {
                syncList = []
            }
            .buttonStyle(.borderless)
            .disabled(syncList.isEmpty || syncEngine.progress.isActive)

            Button(action: { showSyncConfirm = true }) {
                Label("sync.syncNow", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .disabled(syncList.isEmpty || syncEngine.progress.isActive)
            .tint(.iTunesBlue)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Sync overlay (progress)

    @ViewBuilder
    private var syncOverlay: some View {
        if syncEngine.progress.isActive {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    switch syncEngine.progress.phase {
                    case .copying:
                        ProgressView(value: syncEngine.progress.fractionComplete)
                            .progressViewStyle(.linear)
                            .frame(width: 320)

                        Text("\(syncEngine.progress.currentTrack)")
                            .font(.subheadline)
                            .foregroundColor(.primary)

                        Text("\(syncEngine.progress.completedTracks) of \(syncEngine.progress.totalTracks)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                    case .writing:
                        ProgressView()
                        Text("sync.writing")

                    case .ejecting:
                        ProgressView()
                        Text("sync.ejecting")

                    default:
                        EmptyView()
                    }
                }
                .padding(32)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(radius: 12)
                )
            }
        } else if case .done = syncEngine.progress.phase {
            // Brief "done" toast — auto-dismisses after 2s
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Label("sync.done", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Capsule().fill(Color.green.opacity(0.85)))
                        .padding()
                    Spacer()
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                requestVolumeAccess(for: device)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    syncEngine.progress = .init()
                    loadDeviceTracks()
                }
            }
        } else if case let .failed(msg) = syncEngine.progress.phase {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Label("sync.failed", systemImage: "xmark.circle.fill")
                            .foregroundColor(.white)
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(12)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
                    .padding()
                    Spacer()
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    syncEngine.progress = .init()
                }
            }
        }
    }

    // MARK: Helpers

    private func sectionHeader<Accessory: View>(title: String, count: Int, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Text("(\(count))")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func loadDeviceTracks() {
        do {
            let db = try syncEngine.readDatabase(from: device)
            deviceTracks = db.tracks
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func doSync() {
        Task {
            await syncEngine.sync(songs: syncList, to: device)
        }
    }

    private func doEject() {
        syncEngine.eject(device: device) { _ in }
    }
    
    private func requestVolumeAccess(for device: iPodDevice) {
        let panel = NSOpenPanel()
        panel.message = "Select your iPod to allow ClassicTunes to sync music to it."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = device.volumeURL
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Store the security-scoped URL for use during sync
            _ = url.startAccessingSecurityScopedResource()
            syncEngine.grantedVolumeURL = url
        }
    }
}

// MARK: - Sync Song Row

private struct SyncSongRow: View {
    let song: Song
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Artwork thumbnail
            Group {
                if let img = song.artworkImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        )
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Duration
            if let dur = song.duration {
                Text(formatDuration(dur))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Song Picker Sheet

struct SongPickerSheet: View {
    let allSongs: [Song]
    let alreadySelected: [Song]
    let onConfirm: ([Song]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selected: Set<UUID> = []

    private var filtered: [Song] {
        guard !searchText.isEmpty else { return allSongs }
        let q = searchText.lowercased()
        return allSongs.filter {
            $0.title.lowercased().contains(q) ||
            $0.artist.lowercased().contains(q) ||
            $0.album.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("sync.chooseSongs")
                    .font(.title3.bold())
                Spacer()
                Button("picker.done") {
                    let chosen = allSongs.filter { selected.contains($0.id) }
                    onConfirm(chosen)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.iTunesBlue)
                .disabled(selected.isEmpty)
            }
            .padding()

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("toolbar.search", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            // Song list
            List(filtered, selection: $selected) { song in
                HStack(spacing: 10) {
                    Group {
                        if let img = song.artworkImage {
                            Image(nsImage: img).resizable().scaledToFill()
                        } else {
                            Color.gray.opacity(0.3)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).font(.body).lineLimit(1)
                        Text("\(song.artist) — \(song.album)")
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }

                    Spacer()

                    // Already on sync list badge
                    if alreadySelected.contains(where: { $0.id == song.id }) {
                        Text("picker.queued")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.iTunesBlue.opacity(0.2)))
                            .foregroundColor(.iTunesBlue)
                    }

                    if let dur = song.duration {
                        Text(formatDuration(dur))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(song.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Divider()

            // Footer
            HStack {
                Text("\(selected.count) selected")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("picker.cancel") { dismiss() }
                    .buttonStyle(.borderless)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 500)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Sidebar device entry
// Add this inside SidebarView's Section("sidebar.library") when a device is connected.

struct SidebarDeviceEntry: View {
    let device: iPodDevice
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Label(device.volumeName, systemImage: "ipodshuffle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ITunesSidebarButtonStyle(selected: isSelected))
    }
}

// MARK: - Byte formatter

private func formatBytes(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1.0 { return String(format: "%.1f GB", gb) }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1.0 { return String(format: "%.0f MB", mb) }
    return "\(bytes) B"
}
