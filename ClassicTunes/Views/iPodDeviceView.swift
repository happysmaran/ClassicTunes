import SwiftUI
import AppKit
import AVKit

// Looked up with an English fallback so a language without a translation shows readable text
// instead of the key.
private func loc(_ key: StaticString, _ fallback: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: fallback)
}

// MARK: - Root iPod Panel

// The page shown when an iPod is connected, laid out like iTunes' device page: tabs along the
// top (Summary, Music), a capacity bar with the Sync button along the bottom. Music is staged
// here and only written to the iPod when Sync is pressed.
struct iPodDeviceView: View {
    @Environment(\.themeColor) private var themeColor
    @Environment(\.colorScheme) private var colorScheme
    let device: iPodDevice
    @ObservedObject var syncEngine: iPodSyncEngine
    var allLibrarySongs: [Song]
    // User playlists written to iTunesDB iPods; Shuffles have no playlist support.
    var playlists: [Playlist] = []

    private enum Tab: Hashable { case summary, music }

    @State private var tab: Tab = .summary
    // Tracks currently stored on the connected device, as read from its database.
    @State private var deviceTracks: [iTunesSD_BETrack] = []
    @State private var info = iPodDeviceInfo()
    // Measured after each load because the free space captured when the iPod was detected goes
    // stale as soon as a sync finishes.
    @State private var audioBytes: Int64 = 0
    @State private var freeBytes: Int64?
    @State private var loadError: String?
    @State private var isLoadingTracks = false

    @State private var syncList: [Song] = []
    @State private var selectedSongs: Set<UUID> = []
    @State private var syncModeOverride: SyncMode?
    // When on, the whole library is kept on the iPod and re-synced as the library changes, like
    // iTunes' automatic management.
    @State private var autoSync = false
    @State private var didAutoSyncOnConnect = false

    @State private var showSongPicker = false
    @State private var showEjectAlert = false
    @State private var showSyncConfirm = false

    // MARK: Derived values

    private var syncMode: SyncMode {
        syncModeOverride ?? iPodSyncEngine.defaultMode(for: device.generation)
    }
    private var songsToSync: [Song] { autoSync ? allLibrarySongs : syncList }
    // Automatic management has to remove songs deleted from the library, so it always mirrors.
    private var effectiveMode: SyncMode { autoSync ? .mirror : syncMode }
    private var autoSyncKey: String { "autoSync.\(device.volumeName)" }
    // Changes whenever a song is added, removed or edited, which is what should trigger a re-sync.
    private var libraryFingerprint: Int {
        var hasher = Hasher()
        for song in allLibrarySongs {
            hasher.combine(song.id); hasher.combine(song.title); hasher.combine(song.artist); hasher.combine(song.album)
        }
        return hasher.finalize()
    }
    private var capacity: Int64 { device.capacity }
    private var free: Int64 { min(freeBytes ?? device.freeSpace, capacity) }
    private var used: Int64 { max(capacity - free, 0) }
    private var audio: Int64 { min(audioBytes, used) }
    private var other: Int64 { max(used - audio, 0) }
    private var isBusy: Bool { syncEngine.progress.isActive }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Group {
                switch tab {
                case .summary: summaryTab
                case .music: musicTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            capacityBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            autoSync = UserDefaults.standard.bool(forKey: autoSyncKey)
            loadDeviceTracks()
        }
        .onChange(of: autoSync) { _, on in
            UserDefaults.standard.set(on, forKey: autoSyncKey)
            if on { autoSyncIfIdle() }
        }
        .onChange(of: libraryFingerprint) { _, _ in
            if autoSync { autoSyncIfIdle() }
        }
        .sheet(isPresented: $showSongPicker) {
            SongPickerSheet(
                allSongs: allLibrarySongs,
                alreadySelected: syncList,
                onConfirm: { chosen in
                    let existing = Set(syncList.map { $0.id })
                    syncList.append(contentsOf: chosen.filter { !existing.contains($0.id) })
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
            Text(syncConfirmMessage)
        }
        .overlay(syncOverlay)
    }

    // Spelled out per mode because replacing the iPod's contents and adding to them need very
    // different warnings.
    private var syncConfirmMessage: String {
        switch effectiveMode {
        case .mirror:
            return String(format: loc("sync.confirm.messageMirror", "The iPod will contain exactly these %d songs. Everything else on it will be removed. Continue?"), songsToSync.count)
        case .additive:
            return String(format: loc("sync.confirm.messageAdd", "These %d songs will be added to the iPod. Nothing on it will be removed. Continue?"), songsToSync.count)
        }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            tabButton(.summary, title: loc("device.tab.summary", "Summary"))
            tabButton(.music, title: loc("device.tab.music", "Music"))
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            Button(action: { showEjectAlert = true }) {
                Image(systemName: "eject.fill")
            }
            .buttonStyle(ClassicPushButtonStyle(compact: true))
            .disabled(isBusy)
            .help("device.eject")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(ClassicBarBackground(edge: .bottom))
    }

    private func tabButton(_ target: Tab, title: String) -> some View {
        let selected = tab == target
        return Button(action: { tab = target }) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(selected
                        ? AnyShapeStyle(LinearGradient(colors: [themeColor.shaded(0.15), themeColor.shaded(-0.25)], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Color.clear))
                )
                .overlay(Capsule().stroke(selected ? Color.black.opacity(0.3) : Color.clear, lineWidth: 0.5))
                .shadow(color: selected ? .black.opacity(0.25) : .clear, radius: 1, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: Summary tab

    private var summaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sectionTitle(loc("device.section.ipod", "iPod"))
                panel {
                    HStack(alignment: .top, spacing: 36) {
                        deviceArtwork
                        infoGrid
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                }

                sectionTitle(loc("device.section.options", "Options"))
                panel { optionsContent }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // The icon macOS itself shows for this volume in Finder, which is the real photo of the model.
    // The system supplies it, so nothing has to be bundled with the app.
    private var deviceArtwork: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: device.volumeURL.path))
            .resizable()
            .scaledToFit()
            .frame(width: 128, height: 128)
    }

    private var artworkSymbol: String {
        switch device.generation {
        case .shuffle1: return "ipodshuffle.gen1"
        case .shuffle2: return "ipodshuffle.gen2"
        case .shuffle3: return "ipodshuffle.gen3"
        default: return "ipod"
        }
    }

    // iTunes' layout: bold labels right-aligned against their values.
    private var infoGrid: some View {
        let model = [info.productType ?? device.generation.rawValue, info.modelNumber].compactMap { $0 }.joined(separator: " · ")
        let rows: [(String, String?)] = [
            (loc("device.info.name", "Name:"), device.volumeName),
            (loc("device.info.model", "Model:"), model),
            (loc("device.info.capacity", "Capacity:"), formatBytes(capacity)),
            (loc("device.info.songs", "Songs:"), isLoadingTracks ? nil : "\(deviceTracks.count)"),
            (loc("device.info.software", "Software Version:"), info.softwareVersion),
            (loc("device.info.serial", "Serial Number:"), info.serialNumber),
        ]
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if let value = row.1, !value.isEmpty {
                    GridRow {
                        Text(row.0)
                            .fontWeight(.semibold)
                            .gridColumnAlignment(.trailing)
                        Text(value)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .font(.system(size: 12))
    }

    private var optionsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(loc("device.options.auto", "Sync the entire music library automatically"), isOn: $autoSync)
            Text(loc("device.options.auto.help", "Keeps every library song on the iPod and updates it when songs are added, changed or deleted. Other songs on the iPod are removed."))
                .font(.caption)
                .foregroundColor(.secondary)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(loc("device.options.syncMode", "When syncing:"))
                    .fontWeight(.semibold)
                Picker("", selection: Binding(get: { syncMode }, set: { syncModeOverride = $0 })) {
                    Text(loc("device.mode.add", "Add the selected songs")).tag(SyncMode.additive)
                    Text(loc("device.mode.mirror", "Make the iPod match the selected songs")).tag(SyncMode.mirror)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(autoSync)
            }
            Text(syncMode == .mirror
                 ? loc("device.mode.mirror.help", "Songs on the iPod that are not in the Music list are removed.")
                 : loc("device.mode.add.help", "Songs already on the iPod are kept."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .font(.system(size: 12))
        .padding(.vertical, 4)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.secondary)
    }

    // The rounded bordered box iTunes puts around each group of settings.
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.6 : 0.5))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            )
    }

    // MARK: Music tab

    private var musicTab: some View {
        HSplitView {
            stagedPane.frame(minWidth: 260)
            devicePane.frame(minWidth: 260)
        }
    }

    // Fixed widths shared by the column header and the rows so they stay aligned.
    private enum Column {
        static let artwork: CGFloat = 24
        static let time: CGFloat = 44
        static let action: CGFloat = 16
        static let index: CGFloat = 28
    }

    private var stagedPane: some View {
        VStack(spacing: 0) {
            paneHeader(title: loc("device.toSync", "Songs to Sync"), count: songsToSync.count) {
                Button(action: addAll) {
                    Text(loc("device.addAll", "Add All"))
                }
                .buttonStyle(ClassicPushButtonStyle(compact: true))
                .disabled(autoSync || isBusy)

                Button(action: { syncList = [] }) {
                    Text(loc("device.clear", "Clear"))
                }
                .buttonStyle(ClassicPushButtonStyle(compact: true))
                .disabled(autoSync || syncList.isEmpty || isBusy)

                Button(action: { showSongPicker = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(ClassicPushButtonStyle(compact: true))
                .disabled(autoSync)
                .help("sync.addSongs")
            }
            if autoSync {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 34)).foregroundColor(.secondary)
                    Text(String(format: loc("device.autoActive", "The entire library (%d songs) is kept on this iPod."), allLibrarySongs.count))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            } else if syncList.isEmpty {
                emptyStagedState
            } else {
                columnHeader {
                    Color.clear.frame(width: Column.artwork, height: 1)
                    Text(loc("device.col.name", "Name")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(loc("device.col.artist", "Artist")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(loc("device.col.time", "Time")).frame(width: Column.time, alignment: .trailing)
                    Color.clear.frame(width: Column.action, height: 1)
                }
                List(selection: $selectedSongs) {
                    ForEach(syncList) { song in
                        SyncSongRow(song: song, onRemove: { syncList.removeAll { $0.id == song.id } })
                            .tag(song.id)
                    }
                    .onMove { from, to in syncList.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onDeleteCommand {
                    syncList.removeAll { selectedSongs.contains($0.id) }
                    selectedSongs = []
                }
            }
        }
    }

    private var emptyStagedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 34))
                .foregroundColor(.secondary)
            Text("sync.dragHere")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("sync.addSongs") { showSongPicker = true }
                .buttonStyle(ClassicPushButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var devicePane: some View {
        VStack(spacing: 0) {
            paneHeader(title: loc("device.onIPod", "On iPod"), count: deviceTracks.count) { EmptyView() }
            if isLoadingTracks {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("device.loading").font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            } else if let loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundColor(.orange)
                    Text(loadError).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            } else if deviceTracks.isEmpty {
                Text("device.empty")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            } else {
                columnHeader {
                    Text("#").frame(width: Column.index, alignment: .trailing)
                    Text(loc("device.col.name", "Name")).frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: Column.action, height: 1)
                }
                List {
                    ForEach(Array(deviceTracks.enumerated()), id: \.offset) { index, track in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: Column.index, alignment: .trailing)
                            Text(track.displayName.isEmpty ? (track.filePath as NSString).lastPathComponent : track.displayName)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(action: { removeDeviceTrack(at: index) }) {
                                Image(systemName: "minus.circle.fill").foregroundColor(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .disabled(isBusy)
                            .frame(width: Column.action)
                        }
                        .font(.system(size: 12))
                        .padding(.vertical, 1)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private func paneHeader<Accessory: View>(title: String, count: Int, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("(\(count))").font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            accessory()
        }
        .padding(.horizontal, 10)
        // Fixed so both panes' headers line up whether or not they carry buttons.
        .frame(height: 30)
        .background(ClassicBarBackground(edge: .bottom))
    }

    private func columnHeader<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Capacity bar

    // The coloured Audio / Other / Free breakdown with the Sync button beside it.
    private var capacityBar: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 1) {
                Text(loc("device.capacity", "Capacity")).font(.system(size: 12, weight: .semibold))
                Text(formatBytes(capacity)).font(.system(size: 11)).foregroundColor(.secondary)
            }

            VStack(spacing: 5) {
                GeometryReader { geo in
                    let total = max(Double(capacity), 1)
                    HStack(spacing: 0) {
                        segment(width: geo.size.width * CGFloat(Double(audio) / total),
                                colors: [themeColor.shaded(0.35), themeColor])
                        segment(width: geo.size.width * CGFloat(Double(other) / total),
                                colors: [Color(red: 1.0, green: 0.88, blue: 0.35), Color(red: 0.93, green: 0.74, blue: 0.1)])
                        Spacer(minLength: 0)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(colorScheme == .dark ? 0.45 : 0.18))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.35), lineWidth: 0.5))
                }
                .frame(height: 14)

                HStack(spacing: 18) {
                    legend(color: themeColor, title: loc("device.audio", "Audio"), bytes: audio)
                    legend(color: Color(red: 0.93, green: 0.74, blue: 0.1), title: loc("device.other", "Other"), bytes: other)
                    legend(color: Color(white: 0.45), title: loc("device.free", "Free"), bytes: free)
                    Spacer()
                }
            }
            .frame(maxWidth: 520)

            Spacer(minLength: 0)

            Button(action: { showSyncConfirm = true }) {
                Text("sync.syncNow").frame(minWidth: 70)
            }
            .buttonStyle(ClassicPushButtonStyle(prominent: true))
            .disabled(songsToSync.isEmpty || isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(ClassicBarBackground(edge: .top))
    }

    private func segment(width: CGFloat, colors: [Color]) -> some View {
        Rectangle()
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .frame(width: max(width, 0))
    }

    private func legend(color: Color, title: String, bytes: Int64) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.35), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 10, weight: .semibold))
                Text(formatBytes(bytes)).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Sync overlay (progress)

    @ViewBuilder
    private var syncOverlay: some View {
        if syncEngine.progress.isActive {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: artworkSymbol)
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    switch syncEngine.progress.phase {
                    case .copying:
                        Text(loc("sync.syncing", "Syncing…")).font(.headline)
                        ProgressView(value: syncEngine.progress.fractionComplete)
                            .progressViewStyle(.linear)
                            .tint(themeColor)
                            .frame(width: 320)
                        Text(syncEngine.progress.currentTrack)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(String(format: NSLocalizedString("sync.progress", comment: ""), syncEngine.progress.completedTracks, syncEngine.progress.totalTracks))
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
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(radius: 12)
                )
            }
        } else if case .done = syncEngine.progress.phase {
            toast(Label("sync.done", systemImage: "checkmark.circle.fill"), color: .green)
                .onAppear {
                    // Files were just written, so the volume grant is re-confirmed before the
                    // list is re-read.
                    requestVolumeAccess(for: device)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        syncEngine.progress = .init()
                        loadDeviceTracks()
                    }
                }
        } else if case let .failed(message) = syncEngine.progress.phase {
            toast(
                VStack(spacing: 4) {
                    Label("sync.failed", systemImage: "xmark.circle.fill")
                    Text(message).font(.caption).opacity(0.85).lineLimit(3)
                },
                color: .red
            )
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { syncEngine.progress = .init() }
            }
        }
    }

    private func toast<Content: View>(_ content: Content, color: Color) -> some View {
        VStack {
            Spacer()
            content
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.88)))
                .padding(.bottom, 70)
        }
        .frame(maxWidth: .infinity)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Actions

    private func loadDeviceTracks() {
        Task { await loadDeviceTracksAsync() }
    }

    // Reads the device's database, resolves a display name per track where the database has
    // none, and measures how the space is used.
    private func loadDeviceTracksAsync() async {
        await MainActor.run {
            isLoadingTracks = true
            loadError = nil
        }

        if syncEngine.grantedVolumeURL == nil {
            syncEngine.grantedVolumeURL = syncEngine.loadPersistedAccess(for: device.bsdName)
        }
        let baseURL = syncEngine.grantedVolumeURL ?? device.volumeURL
        let accessGranted = baseURL.startAccessingSecurityScopedResource()
        defer { if accessGranted { baseURL.stopAccessingSecurityScopedResource() } }

        var tracks: [iTunesSD_BETrack] = []
        do {
            if device.generation == .classic {
                do {
                    tracks = try ClassicBackend.loadDocument(base: baseURL).tracks().map { track in
                        var entry = iTunesSD_BETrack()
                        entry.filePath = track.devicePath
                        entry.displayName = track.displayName
                        return entry
                    }
                } catch ITunesDBError.noDatabase {
                    // A freshly restored iPod simply has nothing on it yet.
                    tracks = []
                }
            } else {
                tracks = try await readShuffleTracks(base: baseURL)
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                deviceTracks = []
                isLoadingTracks = false
            }
            return
        }

        let audioSize = tracks.reduce(Int64(0)) {
            $0 + DeviceFiles.fileSize(DeviceFiles.url(base: baseURL, devicePath: $1.filePath))
        }
        let freeSpace = DeviceFiles.availableBytes(at: baseURL)
        let deviceInfo = iPodDeviceInfo.read(base: baseURL)
        await MainActor.run {
            deviceTracks = tracks
            audioBytes = audioSize
            freeBytes = freeSpace
            info = deviceInfo
            isLoadingTracks = false
            // Once per connection, to catch changes made while the iPod was unplugged.
            if autoSync && !didAutoSyncOnConnect {
                didAutoSyncOnConnect = true
                autoSyncIfIdle()
            }
        }
    }

    private func addAll() {
        let existing = Set(syncList.map { $0.id })
        syncList.append(contentsOf: allLibrarySongs.filter { !existing.contains($0.id) })
    }

    // Shuffle databases hold only paths, so a readable name comes from each file's tags.
    private func readShuffleTracks(base: URL) async throws -> [iTunesSD_BETrack] {
        let dbURL = base.appendingPathComponent("iPod_Control/iTunes/iTunesSD")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

        var tracks = try ShuffleDatabaseFormat.trackPaths(in: Data(contentsOf: dbURL)).map { path -> iTunesSD_BETrack in
            var entry = iTunesSD_BETrack()
            entry.filePath = path
            return entry
        }
        await withTaskGroup(of: (Int, String).self) { group in
            for index in tracks.indices {
                let path = tracks[index].filePath
                let fileURL = DeviceFiles.url(base: base, devicePath: path)
                group.addTask {
                    let asset = AVAsset(url: fileURL)
                    let metadata = try? await asset.load(.commonMetadata)
                    let title = try? await metadata?.first { $0.commonKey == .commonKeyTitle }?.load(.stringValue)
                    let artist = try? await metadata?.first { $0.commonKey == .commonKeyArtist }?.load(.stringValue)
                    let display = [title, artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
                    return (index, display.isEmpty ? (path as NSString).lastPathComponent : display)
                }
            }
            for await (index, name) in group { tracks[index].displayName = name }
        }
        return tracks
    }

    private func removeDeviceTrack(at index: Int) {
        Task {
            do {
                try await syncEngine.removeTrack(at: index, from: device)
            } catch {
                await MainActor.run { loadError = error.localizedDescription }
            }
            // Re-read rather than patching the list, so what is shown is what the iPod holds.
            await loadDeviceTracksAsync()
        }
    }

    private func doSync() {
        let mode = effectiveMode
        let songs = songsToSync
        Task { await syncEngine.sync(songs: songs, playlists: playlists, to: device, mode: mode) }
    }

    // Skipped while something else is running so a burst of library edits cannot start
    // overlapping syncs.
    private func autoSyncIfIdle() {
        guard !isBusy, !isLoadingTracks, !allLibrarySongs.isEmpty else { return }
        doSync()
    }

    private func doEject() {
        syncEngine.eject(device: device) { _ in }
    }

    // Ensures there is a saved, security-scoped grant for the volume, asking once if not.
    private func requestVolumeAccess(for device: iPodDevice) {
        if let savedURL = syncEngine.loadPersistedAccess(for: device.bsdName) {
            syncEngine.grantedVolumeURL = savedURL
            loadDeviceTracks()
            return
        }
        let panel = NSOpenPanel()
        panel.message = NSLocalizedString("sync.access.message", comment: "")
        panel.prompt = NSLocalizedString("sync.access.prompt", comment: "")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = device.volumeURL
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            _ = url.startAccessingSecurityScopedResource()
            syncEngine.persistAccess(for: url, bsdName: device.bsdName)
            loadDeviceTracks()
        }
    }
}

// MARK: - Shared chrome

// Top and bottom bars use the same brushed-metal gradient as the main toolbar so the device page
// reads as part of the same window.
private struct ClassicBarBackground: View {
    enum Edge { case top, bottom }
    // The edge that carries the dark separator line, facing the content.
    let edge: Edge
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            LinearGradient(
                colors: dark ? [Color(white: 0.34), Color(white: 0.24), Color(white: 0.18)]
                             : [Color(white: 0.93), Color(white: 0.80), Color(white: 0.70)],
                startPoint: .top, endPoint: .bottom)
            LinearGradient(
                colors: [Color.white.opacity(dark ? 0.08 : 0.35), Color.white.opacity(0)],
                startPoint: .top, endPoint: .center)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(edge == .top ? Color.black.opacity(dark ? 0.6 : 0.4) : Color.white.opacity(dark ? 0.25 : 0.7)).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(edge == .bottom ? Color.black.opacity(dark ? 0.6 : 0.4) : Color.white.opacity(dark ? 0.25 : 0.7)).frame(height: 1)
        }
    }
}

// Glossy rounded button in the toolbar's style; `prominent` tints it with the theme colour for
// the main action.
private struct ClassicPushButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeColor) private var themeColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let dark = colorScheme == .dark
        let fill: [Color] = prominent
            ? [themeColor.shaded(0.3), themeColor.shaded(-0.15)]
            : (dark ? [Color(white: 0.42), Color(white: 0.28)] : [Color.white, Color(white: 0.82)])
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .foregroundColor(prominent ? .white : .primary)
            .padding(.horizontal, compact ? 9 : 16)
            .padding(.vertical, compact ? 3 : 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: fill, startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.black.opacity(0.35), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
            )
            .brightness(configuration.isPressed ? -0.12 : 0)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Sync Song Row

// One staged song: artwork, name, artist, length and a remove button, on a single line like an
// iTunes list row.
private struct SyncSongRow: View {
    let song: Song
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let image = song.artworkImage {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.3))
                        .overlay(Image(systemName: "music.note").font(.system(size: 9)).foregroundColor(.secondary))
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            Text(song.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(song.artist).foregroundColor(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(song.duration.map(Self.format) ?? "")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill").foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .frame(width: 16)
        }
        .font(.system(size: 12))
        .padding(.vertical, 1)
    }

    private static func format(_ time: TimeInterval) -> String {
        String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
    }
}

// MARK: - Song Picker Sheet

// Modal sheet for browsing the full library and multi-selecting songs to add to the sync list.
// Supports live search across title, artist and album, and flags songs already queued.
struct SongPickerSheet: View {
    @Environment(\.themeColor) private var themeColor
    let allSongs: [Song]
    let alreadySelected: [Song]
    let onConfirm: ([Song]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selected: Set<UUID> = []

    private var filtered: [Song] {
        guard !searchText.isEmpty else { return allSongs }
        let query = searchText.lowercased()
        return allSongs.filter {
            $0.title.lowercased().contains(query) ||
            $0.artist.lowercased().contains(query) ||
            $0.album.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("sync.chooseSongs").font(.title3.bold())
                Spacer()
                Button("picker.done") {
                    onConfirm(allSongs.filter { selected.contains($0.id) })
                    dismiss()
                }
                .buttonStyle(ClassicPushButtonStyle(prominent: true))
                .disabled(selected.isEmpty)
            }
            .padding()

            Divider()

            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("toolbar.search", text: $searchText).textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            List(filtered, selection: $selected) { song in
                HStack(spacing: 10) {
                    Group {
                        if let image = song.artworkImage {
                            Image(nsImage: image).resizable().scaledToFill()
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

                    if alreadySelected.contains(where: { $0.id == song.id }) {
                        Text("picker.queued")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.tint.opacity(0.2)))
                            .foregroundStyle(.tint)
                    }

                    if let duration = song.duration {
                        Text(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(song.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Divider()

            HStack {
                Text(String(format: NSLocalizedString("picker.selected", comment: ""), selected.count))
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(loc("picker.selectAll", "Select All")) { selected.formUnion(filtered.map { $0.id }) }
                    .buttonStyle(.borderless)
                Button("picker.cancel") { dismiss() }.buttonStyle(.borderless)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 500)
    }
}

// MARK: - Sidebar device entry

// Sidebar row for the connected iPod, used to navigate into the device page.
struct SidebarDeviceEntry: View {
    let device: iPodDevice
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Label(device.volumeName, systemImage: "ipod")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ITunesSidebarButtonStyle(selected: isSelected))
    }
}

// MARK: - Byte formatter

private func formatBytes(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1.0 { return String(format: "%.2f GB", gb) }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1.0 { return String(format: "%.0f MB", mb) }
    return "\(bytes) B"
}
