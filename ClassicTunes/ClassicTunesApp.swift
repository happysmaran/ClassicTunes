import SwiftUI

@main
struct ClassicTunesApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 600)
                .background(Color.clear)
                .edgesIgnoringSafeArea(.top) // Let SwiftUI extend into titlebar
                .preferredColorScheme(.light) // Force light mode
                .colorScheme(.light) // Additional enforcement
        }
        .windowStyle(HiddenTitleBarWindowStyle()) // Hide native title bar
        .commands {
            // Remove system appearance toggle
            CommandGroup(replacing: .sidebar) { }
        }
    }
}
