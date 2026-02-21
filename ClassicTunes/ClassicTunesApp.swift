import SwiftUI

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

            CommandMenu("File") {
                Button("Preferences…") {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .frame(minWidth: 480, minHeight: 200)
                .environmentObject(appearanceManager)
        }
    }
}
