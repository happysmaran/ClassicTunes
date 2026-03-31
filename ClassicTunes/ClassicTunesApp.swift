import SwiftUI

struct DeletePlaylistActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var deletePlaylistAction: (() -> Void)? {
        get { self[DeletePlaylistActionKey.self] }
        set { self[DeletePlaylistActionKey.self] = newValue }
    }
}

@main
struct ClassicTunesApp: App {
    @StateObject private var appearanceManager = AppearanceManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 600)
                .background(Color.clear)
                .edgesIgnoringSafeArea(.top)
                .environmentObject(appearanceManager)
                .preferredColorScheme(appearanceManager.currentColorScheme())
                .id(appearanceManager.appAppearance) // Force view refresh when appearance changes
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .commands {
            CommandGroup(replacing: .sidebar) { }
            PlaylistCommands()
        }

        Settings {
            SettingsView()
                .frame(minWidth: 480, minHeight: 200)
                .environmentObject(appearanceManager)
        }
    }
}


struct PlaylistCommands: Commands {
    @FocusedValue(\.deletePlaylistAction) private var deleteAction: (() -> Void)?

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Delete Playlist") {
                deleteAction?()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(deleteAction == nil)
        }
    }
}
