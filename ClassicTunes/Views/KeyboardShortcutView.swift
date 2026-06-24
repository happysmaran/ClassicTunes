import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("shortcut.newPlaylist") private var shortcutNewPlaylist: String = "⌘N"
    @AppStorage("shortcut.importMusic") private var shortcutImportMusic: String = "⌘O"
    @AppStorage("shortcut.importPlaylist") private var shortcutImportPlaylist: String = "⌘⇧O"
    @AppStorage("shortcut.exportPlaylist") private var shortcutExportPlaylist: String = "⌘⇧E"
    
    @AppStorage("shortcut.deletePlaylist") private var shortcutDeletePlaylist: String = "⌫"
    @AppStorage("shortcut.find") private var shortcutFind: String = "⌘F"
    
    @AppStorage("shortcut.showAsList") private var shortcutShowAsList: String = "⌘1"
    @AppStorage("shortcut.showAsAlbums") private var shortcutShowAsAlbums: String = "⌘2"
    @AppStorage("shortcut.showAsCoverFlow") private var shortcutShowAsCoverFlow: String = "⌘3"
    @AppStorage("shortcut.toggleUpNext") private var shortcutToggleUpNext: String = "⌘U"
    @AppStorage("shortcut.toggleLyrics") private var shortcutToggleLyrics: String = "⌘L"
    @AppStorage("shortcut.switchToMiniPlayer") private var shortcutSwitchToMiniPlayer: String = "⌘⇧M"
    
    @AppStorage("shortcut.playPause") private var shortcutPlayPause: String = "Space"
    @AppStorage("shortcut.nextSong") private var shortcutNextSong: String = "⌘→"
    @AppStorage("shortcut.previousSong") private var shortcutPreviousSong: String = "⌘←"
    @AppStorage("shortcut.increaseVolume") private var shortcutIncreaseVolume: String = "⌘↑"
    @AppStorage("shortcut.decreaseVolume") private var shortcutDecreaseVolume: String = "⌘↓"
    @AppStorage("shortcut.toggleMute") private var shortcutToggleMute: String = "⌘⇧↓"
    @AppStorage("shortcut.shuffle") private var shortcutShuffle: String = "⌘S"
    @AppStorage("shortcut.repeat") private var shortcutRepeat: String = "⌘R"

    private struct ShortcutGroup {
        let title: LocalizedStringKey
        let items: [(LocalizedStringKey, String)]
    }

    private var groups: [ShortcutGroup] {
        [
            ShortcutGroup(title: "shortcuts.group.file", items: [
                ("menu.newPlaylist", shortcutNewPlaylist),
                ("menu.importMusic", shortcutImportMusic),
                ("menu.importPlaylist", shortcutImportPlaylist),
                ("menu.exportPlaylist", shortcutExportPlaylist)
            ]),
            ShortcutGroup(title: "shortcuts.group.edit", items: [
                ("menu.deletePlaylist", shortcutDeletePlaylist),
                ("menu.find", shortcutFind)
            ]),
            ShortcutGroup(title: "shortcuts.group.view", items: [
                ("menu.showAsList", shortcutShowAsList),
                ("menu.showAsAlbums", shortcutShowAsAlbums),
                ("menu.showAsCoverFlow", shortcutShowAsCoverFlow),
                ("menu.toggleUpNext", shortcutToggleUpNext),
                ("menu.toggleLyrics", shortcutToggleLyrics),
                ("menu.switchToMiniPlayer", shortcutSwitchToMiniPlayer)
            ]),
            ShortcutGroup(title: "shortcuts.group.controls", items: [
                ("menu.playPause", shortcutPlayPause),
                ("menu.nextSong", shortcutNextSong),
                ("menu.previousSong", shortcutPreviousSong),
                ("menu.increaseVolume", shortcutIncreaseVolume),
                ("menu.decreaseVolume", shortcutDecreaseVolume),
                ("menu.toggleMute", shortcutToggleMute),
                ("menu.shuffle", shortcutShuffle),
                ("menu.repeat", shortcutRepeat)
            ])
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("shortcuts.title")
                .font(.title2.bold())
                .padding([.top, .horizontal])
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groups.indices, id: \.self) { i in
                        let group = groups[i]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.accentColor)
                                .textCase(.uppercase)

                            VStack(spacing: 0) {
                                ForEach(group.items.indices, id: \.self) { j in
                                    let item = group.items[j]
                                    HStack {
                                        Text(item.0)
                                        Spacer()
                                        Text(item.1)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    
                                    if j < group.items.count - 1 {
                                        Divider().padding(.leading, 10)
                                    }
                                }
                            }
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("shortcuts.close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 380, height: 460)
    }
}
