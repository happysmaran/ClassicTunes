import SwiftUI
import Combine

// The set of selectable app theme (accent) colors, offered as a picker in Settings.
// `system` tracks the user's macOS accent/highlight color preference (NSColor.controlAccentColor)
// instead of a fixed value, so the app matches whatever the user picks in System Settings.
enum ThemeColorOption: String, CaseIterable, Identifiable {
    case system, blue, graphite, red, orange, yellow, green, purple, pink

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .system: return Color(nsColor: .controlAccentColor)
        case .blue: return .iTunesBlue
        case .graphite: return Color(red: 0.55, green: 0.55, blue: 0.58)
        case .red: return Color(red: 0.85, green: 0.24, blue: 0.24)
        case .orange: return Color(red: 0.92, green: 0.55, blue: 0.15)
        case .yellow: return Color(red: 0.93, green: 0.78, blue: 0.15)
        case .green: return Color(red: 0.30, green: 0.68, blue: 0.31)
        case .purple: return Color(red: 0.58, green: 0.35, blue: 0.85)
        case .pink: return Color(red: 0.93, green: 0.36, blue: 0.61)
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .system: return "settings.themeColor.system"
        case .blue: return "settings.themeColor.blue"
        case .graphite: return "settings.themeColor.graphite"
        case .red: return "settings.themeColor.red"
        case .orange: return "settings.themeColor.orange"
        case .yellow: return "settings.themeColor.yellow"
        case .green: return "settings.themeColor.green"
        case .purple: return "settings.themeColor.purple"
        case .pink: return "settings.themeColor.pink"
        }
    }
}

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

    // Persisted theme (accent) color selection, applied app-wide via `.tint(...)`.
    @AppStorage("appThemeColor") var themeColorName: String = ThemeColorOption.blue.rawValue {
        didSet {
            objectWillChange.send()
        }
    }

    // Resolves the persisted theme color name to an actual SwiftUI Color.
    var themeColor: Color {
        (ThemeColorOption(rawValue: themeColorName) ?? .blue).color
    }

    private var systemColorObserver: NSObjectProtocol?

    init() {
        // When the "system" theme is selected, keep the app's tint in sync if the
        // user changes their accent color preference in System Settings while running.
        systemColorObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        if let systemColorObserver {
            NotificationCenter.default.removeObserver(systemColorObserver)
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
