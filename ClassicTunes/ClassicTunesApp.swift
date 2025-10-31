import SwiftUI

@main
struct ClassicTunesApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 600)
                .background(Color.clear)
                .edgesIgnoringSafeArea(.top) // Let SwiftUI extend into titlebar
        }
        .windowStyle(HiddenTitleBarWindowStyle()) // Hide native title bar
    }
}
