import SwiftUI
import Combine

class AppearanceManager: ObservableObject {
    @AppStorage("appAppearance") var appAppearance: String = "system" {
        didSet {
            applyAppearance()
        }
    }

    func currentColorScheme() -> ColorScheme? {
        switch appAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    func applyAppearance() {
        if let window = NSApplication.shared.windows.first {
            window.appearance = NSAppearance(named: appAppearance == "light" ? .aqua :
                                           appAppearance == "dark" ? .darkAqua :
                                           .vibrantDark)
        }
        
        objectWillChange.send()
    }
}
