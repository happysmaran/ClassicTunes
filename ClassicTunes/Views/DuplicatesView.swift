import SwiftUI
import AppKit

// Lists sets of songs that look like the same recording. User has full control, of course.
struct DuplicatesView: View {
    let songs: [Song]
    var onTrashed: ([Song]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var groups: [[Song]] = []
    @State private var isSearching = true
    @State private var pendingTrash: Song?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("duplicates.title").font(.headline)
                Spacer()
                if !isSearching && !groups.isEmpty {
                    Text(String(format: NSLocalizedString("duplicates.found", comment: ""), groups.count))
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            Divider()

            if isSearching {
                Text("duplicates.finding").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                Text("duplicates.none").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        Section {
                            ForEach(group) { song in row(song) }
                        } header: {
                            Text("\(group[0].title) — \(group[0].artist)")
                        }
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("duplicates.done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 520)
        .task {
            let all = songs
            groups = await Task.detached { DuplicateFinder.groups(in: all) }.value
            isSearching = false
        }
        .alert(
            String(format: NSLocalizedString("duplicates.confirmTitle", comment: ""), pendingTrash?.title ?? ""),
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })
        ) {
            Button("duplicates.moveToTrash", role: .destructive) {
                if let song = pendingTrash { trash(song) }
                pendingTrash = nil
            }
            Button("duplicates.cancel", role: .cancel) { pendingTrash = nil }
        } message: {
            Text("duplicates.confirmMessage")
        }
        .alert("duplicates.failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("duplicates.done", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ song: Song) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(song.album) · \(detail(for: song))").font(.subheadline)
                Text((song.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([song.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help(Text("duplicates.showInFinder"))
            Button { pendingTrash = song } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(Text("duplicates.moveToTrash"))
        }
    }

    private func detail(for song: Song) -> String {
        let size = (try? song.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        return [song.url.pathExtension.uppercased(), size].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func trash(_ song: Song) {
        do {
            try FileManager.default.trashItem(at: song.url, resultingItemURL: nil)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        groups = groups.map { $0.filter { $0.id != song.id } }.filter { $0.count > 1 }
        onTrashed([song])
    }
}
