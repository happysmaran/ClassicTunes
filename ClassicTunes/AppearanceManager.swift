import SwiftUI
import Combine
import UniformTypeIdentifiers

// The set of selectable app theme (accent) colors, offered as a picker in Settings.
// `system` tracks the user's macOS accent/highlight color preference (NSColor.controlAccentColor)
// instead of a fixed value, so the app matches whatever the user picks in System Settings.
enum ThemeColorOption: String, CaseIterable, Identifiable {
    case system, blue, graphite, red, orange, yellow, green, purple, pink

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .system: return Self.systemAccentColor
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

    // The macOS accent color except if it uses stock macOS blue it is swapped
    // for iTunes blue
    private static var systemAccentColor: Color {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        let stockBlue = NSColor.systemBlue.usingColorSpace(.sRGB)
        if let accent, let stockBlue,
           abs(accent.redComponent - stockBlue.redComponent) < 0.02,
           abs(accent.greenComponent - stockBlue.greenComponent) < 0.02,
           abs(accent.blueComponent - stockBlue.blueComponent) < 0.02 {
            return .iTunesBlue
        }
        return Color(nsColor: .controlAccentColor)
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

// Exposes the selected theme color through the environment for views that need a concrete
// `Color` (gradients, derived shades) rather than the `.tint` shape style.
private struct ThemeColorKey: EnvironmentKey {
    static let defaultValue: Color = .iTunesBlue
}

extension EnvironmentValues {
    var themeColor: Color {
        get { self[ThemeColorKey.self] }
        set { self[ThemeColorKey.self] = newValue }
    }
}

extension Color {
    // Mixes this color toward white (positive) or black (negative) by `amount` (0...1).
    func shaded(_ amount: Double) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let target: NSColor = amount >= 0 ? .white : .black
        return Color(nsColor: base.blended(withFraction: CGFloat(abs(amount)), of: target) ?? base)
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

// MARK: - View background customization

// The views whose background can be customized in Settings. Each target persists its own
// style ("default", "light", "dark" or "custom"), custom color (hex) and background image file name.
enum BackgroundTarget {
    case albumGrid, songList

    var styleKey: String {
        switch self {
        case .albumGrid: return "albumGridBackgroundStyle"
        case .songList: return "songListBackgroundStyle"
        }
    }

    var colorKey: String {
        switch self {
        case .albumGrid: return "albumGridCustomColor"
        case .songList: return "songListCustomColor"
        }
    }

    var imageKey: String {
        switch self {
        case .albumGrid: return "albumGridBackgroundImage"
        case .songList: return "songListBackgroundImage"
        }
    }

    // The style restored by "Reset". The song list has an extra "default" style (plain system look).
    var defaultStyle: String {
        switch self {
        case .albumGrid: return "dark"
        case .songList: return "default"
        }
    }

    static let defaultCustomColorHex = "#3A3A3C"

    // Restores this target's style, custom color and image directly in UserDefaults
    // (the @AppStorage properties in views pick the change up automatically).
    func resetStorage() {
        let defaults = UserDefaults.standard
        BackgroundImageStore.remove(named: defaults.string(forKey: imageKey) ?? "")
        defaults.set("", forKey: imageKey)
        defaults.set(defaultStyle, forKey: styleKey)
        defaults.set(Self.defaultCustomColorHex, forKey: colorKey)
    }
}

// Stores user-picked background images as files in Application Support, so only a file name
// needs to live in UserDefaults.
enum BackgroundImageStore {
    private static let cache = NSCache<NSString, NSImage>()

    private static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClassicTunes/Backgrounds", isDirectory: true)
    }

    // Copies the picked image into the store under a unique name and returns that name.
    static func save(from sourceURL: URL) -> String? {
        guard let directory else { return nil }
        let name = UUID().uuidString + "." + (sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: directory.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    static func image(named name: String) -> NSImage? {
        guard !name.isEmpty, let directory else { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    static func remove(named name: String) {
        guard !name.isEmpty, let directory else { return }
        cache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

extension Color {
    // Parses a "#RRGGBB" string.
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    // Perceived-brightness check used to pick a readable text color scheme over a custom background.
    var isDark: Bool {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.5
    }
}

// Draws the target's chosen background image (if any), filling and clipping to the available space.
struct BackgroundImageLayer: View {
    @AppStorage private var imageName: String

    init(target: BackgroundTarget) {
        _imageName = AppStorage(wrappedValue: "", target.imageKey)
    }

    var body: some View {
        if let image = BackgroundImageStore.image(named: imageName) {
            GeometryReader { proxy in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
        }
    }
}

// Bridges NSColorPanel's target/action callback to a closure, so SwiftUI can open the panel on demand.
final class ColorPanelBinder: NSObject {
    private var onChange: ((NSColor) -> Void)?

    func present(initial: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = initial
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}

// Settings controls for one target: style picker, custom color, background image and reset.
struct BackgroundOptionsSection: View {
    let target: BackgroundTarget
    @AppStorage private var style: String
    @AppStorage private var colorHex: String
    @AppStorage private var imageName: String
    @State private var colorPanelBinder = ColorPanelBinder()

    init(target: BackgroundTarget) {
        self.target = target
        _style = AppStorage(wrappedValue: target.defaultStyle, target.styleKey)
        _colorHex = AppStorage(wrappedValue: BackgroundTarget.defaultCustomColorHex, target.colorKey)
        _imageName = AppStorage(wrappedValue: "", target.imageKey)
    }

    private var isCustom: Bool { style == "custom" }

    var body: some View {
        LabeledContent("settings.albumGrid.background") {
            HStack(spacing: 8) {
                // While "custom" is active no segment matches the selection, so none is highlighted.
                Picker("settings.albumGrid.background", selection: $style) {
                    if target == .songList {
                        Text("settings.system").tag("default")
                    } else {
                        Text("settings.light").tag("light")
                        Text("settings.dark").tag("dark")
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()

                // "Custom" button plus a live color preview; either one opens the system color panel.
                Button(action: pickCustomColor) {
                    Text("settings.background.custom")
                        .fontWeight(isCustom ? .semibold : .regular)
                }
                .tint(isCustom ? nil : Color.secondary)

                Button(action: pickCustomColor) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(hex: colorHex) ?? .gray)
                        .frame(width: 22, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }

        HStack {
            Button("settings.background.chooseImage") { chooseImage() }
            if !imageName.isEmpty {
                Button("settings.background.removeImage") { removeImage() }
            }
            Spacer()
            Button("settings.background.reset") { reset() }
        }
    }

    // Selects the custom style and opens the shared color panel, writing each pick back to storage.
    private func pickCustomColor() {
        style = "custom"
        colorPanelBinder.present(initial: NSColor(Color(hex: colorHex) ?? .gray)) { color in
            colorHex = Color(nsColor: color).hexString
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let newName = BackgroundImageStore.save(from: url) else { return }
        BackgroundImageStore.remove(named: imageName)
        imageName = newName
    }

    private func removeImage() {
        BackgroundImageStore.remove(named: imageName)
        imageName = ""
    }

    private func reset() {
        target.resetStorage()
    }
}
