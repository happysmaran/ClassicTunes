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

extension Color {
    static let iTunesBlue = Color(red: 0.23, green: 0.51, blue: 0.85)
}

extension NSColor {
    static let iTunesBlue = NSColor(red: 0.23, green: 0.51, blue: 0.85, alpha: 1.0)
}

@main
struct ClassicTunesApp: App {
    @StateObject private var appearanceManager = AppearanceManager()
    @StateObject private var deviceMonitor = iPodDeviceMonitor()
    @StateObject private var syncEngine = iPodSyncEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1200, minHeight: 900)
                .background(Color.clear)
                .edgesIgnoringSafeArea(.top)
                .environmentObject(appearanceManager)
                .environmentObject(deviceMonitor)
                .environmentObject(syncEngine)
                .preferredColorScheme(appearanceManager.currentColorScheme())
                .id(appearanceManager.appAppearance)
                .tint(.iTunesBlue)
                .onAppear {
                    NSApp.appearance = NSAppearance(named: .aqua)
                    deviceMonitor.scanMountedVolumes()
                }
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
            Button("menu.deletePlaylist") {
                deleteAction?()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(deleteAction == nil)
        }
    }
}
