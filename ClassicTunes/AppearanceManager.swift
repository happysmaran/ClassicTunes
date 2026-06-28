import SwiftUI
import Combine

// A centralized lifecycle coordinator that maps user skin selections onto core platform window rails.
final class AppearanceManager: ObservableObject {
    // Long-term backing reference key mapping preference selections.
    @AppStorage("appAppearance") var appAppearance: String = "system" {
        didSet {
            // Guarantee layout mutations happen inside the Main Actor context loop
            Task { @MainActor in
                applyAppearance()
            }
        }
    }

    // Evaluates preference state metrics to yield clear conditional style frames for SwiftUI views.
    func currentColorScheme() -> ColorScheme? {
        switch appAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    // Iterates through every application window lane to transition interface properties safely.
    @MainActor
    func applyAppearance() {
        // Resolve target Aqua styles depending on exact string key tokens
        let appearanceName: NSAppearance.Name
        switch appAppearance {
        case "light":
            appearanceName = .aqua
        case "dark":
            appearanceName = .darkAqua
        default:
            // Fall back to standard native system environment styling definitions
            appearanceName = .vibrantDark
        }
        
        let targetAppearance = NSAppearance(named: appearanceName)
        
        // Iterate through ALL windows instead of just the leading array index
        for window in NSApplication.shared.windows {
            if window.appearance != targetAppearance {
                window.appearance = targetAppearance
            }
        }
        
        // Notify downstream SwiftUI layout paths to redraw their content matrices
        objectWillChange.send()
    }
}
