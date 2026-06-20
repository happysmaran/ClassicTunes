import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct ShortcutGroup {
        let title: LocalizedStringKey
        let items: [(LocalizedStringKey, String)]
    }

    private let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "shortcuts.group.file", items: [
            ("menu.newPlaylist", "⌘N"),
            ("menu.importMusic", "⌘O"),
            ("menu.importPlaylist", "⌘⇧O"),
            ("menu.exportPlaylist", "⌘⇧E")
        ]),
        ShortcutGroup(title: "shortcuts.group.edit", items: [
            ("menu.deletePlaylist", "⌫"),
            ("menu.find", "⌘F")
        ]),
        ShortcutGroup(title: "shortcuts.group.view", items: [
            ("menu.showAsList", "⌘1"),
            ("menu.showAsAlbums", "⌘2"),
            ("menu.showAsCoverFlow", "⌘3"),
            ("menu.toggleUpNext", "⌘U"),
            ("menu.toggleLyrics", "⌘L"),
            ("menu.switchToMiniPlayer", "⌘⇧M")
        ]),
        ShortcutGroup(title: "shortcuts.group.controls", items: [
            ("menu.playPause", "Space"),
            ("menu.nextSong", "⌘→"),
            ("menu.previousSong", "⌘←"),
            ("menu.increaseVolume", "⌘↑"),
            ("menu.decreaseVolume", "⌘↓"),
            ("menu.toggleMute", "⌘⇧↓"),
            ("menu.shuffle", "⌘S"),
            ("menu.repeat", "⌘R")
        ])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("shortcuts.title")
                .font(.title2.bold())
                .padding([.top, .horizontal])
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups.indices, id: \.self) { i in
                        let group = groups[i]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title)
                                .font(.headline)
                                .foregroundColor(.secondary)

                            ForEach(group.items.indices, id: \.self) { j in
                                let item = group.items[j]
                                HStack {
                                    Text(item.0)
                                    Spacer()
                                    Text(item.1)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("shortcuts.close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 380, height: 460)
    }
}
