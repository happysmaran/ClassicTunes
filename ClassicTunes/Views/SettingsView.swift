import SwiftUI

// The app's Settings window, with two tabs:
//   1. "General" — appearance (light/dark/system) and album grid background style.
//   2. "Shortcuts" — a reassignable list of keyboard shortcuts for menu actions,
//      grouped by category (File, Edit, View, Controls), with a reset-to-defaults action.
// All preferences are persisted via @AppStorage (backed by UserDefaults).
struct SettingsView: View {
    @EnvironmentObject private var appearanceManager: AppearanceManager
    @AppStorage("albumGridBackgroundStyle") private var albumGridBackgroundStyle: String = "dark"

    // todo
    // Playback-related settings (crossfade, sound enhancer) — declared but
    // not yet wired into a UI section below (marked "todo" by the original author).
    @AppStorage("isCrossfadeEnabled") private var isCrossfadeEnabled: Bool = false
    @AppStorage("crossfadeDuration") private var crossfadeDuration: Double = 6.0
    @AppStorage("isSoundEnhancerEnabled") private var isSoundEnhancerEnabled: Bool = false
    @AppStorage("soundEnhancerIntensity") private var soundEnhancerIntensity: Double = 5.0

    // --- Keyboard shortcut preferences, each persisted individually ---
    // File menu shortcuts
    @AppStorage("shortcut.newPlaylist") private var shortcutNewPlaylist: String = "⌘N"
    @AppStorage("shortcut.importMusic") private var shortcutImportMusic: String = "⌘O"
    @AppStorage("shortcut.importPlaylist") private var shortcutImportPlaylist: String = "⌘⇧O"
    @AppStorage("shortcut.exportPlaylist") private var shortcutExportPlaylist: String = "⌘⇧E"

    // Edit menu shortcuts
    @AppStorage("shortcut.deletePlaylist") private var shortcutDeletePlaylist: String = "⌫"
    @AppStorage("shortcut.find") private var shortcutFind: String = "⌘F"

    // View menu shortcuts
    @AppStorage("shortcut.showAsList") private var shortcutShowAsList: String = "⌘1"
    @AppStorage("shortcut.showAsAlbums") private var shortcutShowAsAlbums: String = "⌘2"
    @AppStorage("shortcut.showAsCoverFlow") private var shortcutShowAsCoverFlow: String = "⌘3"
    @AppStorage("shortcut.toggleUpNext") private var shortcutToggleUpNext: String = "⌘U"
    @AppStorage("shortcut.toggleLyrics") private var shortcutToggleLyrics: String = "⌘L"
    @AppStorage("shortcut.switchToMiniPlayer") private var shortcutSwitchToMiniPlayer: String = "⌘⇧M"

    // Playback control shortcuts
    @AppStorage("shortcut.playPause") private var shortcutPlayPause: String = "Space"
    @AppStorage("shortcut.nextSong") private var shortcutNextSong: String = "⌘→"
    @AppStorage("shortcut.previousSong") private var shortcutPreviousSong: String = "⌘←"
    @AppStorage("shortcut.increaseVolume") private var shortcutIncreaseVolume: String = "⌘↑"
    @AppStorage("shortcut.decreaseVolume") private var shortcutDecreaseVolume: String = "⌘↓"
    @AppStorage("shortcut.toggleMute") private var shortcutToggleMute: String = "⌘⇧↓"
    @AppStorage("shortcut.shuffle") private var shortcutShuffle: String = "⌘S"
    @AppStorage("shortcut.repeat") private var shortcutRepeat: String = "⌘R"

    var body: some View {
        TabView {
            // MARK: - General Tab
            Form {
                Section(header: Text("settings.appearance")) {
                    // Segmented control for choosing app appearance; applying
                    // the new appearance is triggered explicitly via onChange
                    // rather than relying on the AppStorage write alone.
                    Picker("settings.appAppearance", selection: $appearanceManager.appAppearance) {
                        Text("settings.system").tag("system")
                        Text("settings.light").tag("light")
                        Text("settings.dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appearanceManager.appAppearance) { _ in
                        appearanceManager.applyAppearance()
                    }

                    // Explains the currently selected appearance option.
                    Text(helpText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(height: 40, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(header: Text("settings.albumGrid")) {
                    // Light/dark background behind album art in the grid view.
                    Picker("settings.albumGrid.background", selection: $albumGridBackgroundStyle) {
                        Text("settings.light").tag("light")
                        Text("settings.dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }

            // MARK: - Shortcuts Tab
            // Scrollable list of shortcut groups, each rendered as a card-like
            // section via the shortcutSection helper, plus a "Reset Defaults" action.
            ScrollView {
                VStack(spacing: 20) {
                    shortcutSection(title: "shortcuts.group.file") {
                        ShortcutAssignerRow(title: "menu.newPlaylist", shortcut: $shortcutNewPlaylist)
                        ShortcutAssignerRow(title: "menu.importMusic", shortcut: $shortcutImportMusic)
                        ShortcutAssignerRow(title: "menu.importPlaylist", shortcut: $shortcutImportPlaylist)
                        ShortcutAssignerRow(title: "menu.exportPlaylist", shortcut: $shortcutExportPlaylist)
                    }

                    shortcutSection(title: "shortcuts.group.edit") {
                        ShortcutAssignerRow(title: "menu.deletePlaylist", shortcut: $shortcutDeletePlaylist)
                        ShortcutAssignerRow(title: "menu.find", shortcut: $shortcutFind)
                    }

                    shortcutSection(title: "shortcuts.group.view") {
                        ShortcutAssignerRow(title: "menu.showAsList", shortcut: $shortcutShowAsList)
                        ShortcutAssignerRow(title: "menu.showAsAlbums", shortcut: $shortcutShowAsAlbums)
                        ShortcutAssignerRow(title: "menu.showAsCoverFlow", shortcut: $shortcutShowAsCoverFlow)
                        ShortcutAssignerRow(title: "menu.toggleUpNext", shortcut: $shortcutToggleUpNext)
                        ShortcutAssignerRow(title: "menu.toggleLyrics", shortcut: $shortcutToggleLyrics)
                        ShortcutAssignerRow(title: "menu.switchToMiniPlayer", shortcut: $shortcutSwitchToMiniPlayer)
                    }

                    shortcutSection(title: "shortcuts.group.controls") {
                        ShortcutAssignerRow(title: "menu.playPause", shortcut: $shortcutPlayPause)
                        ShortcutAssignerRow(title: "menu.nextSong", shortcut: $shortcutNextSong)
                        ShortcutAssignerRow(title: "menu.previousSong", shortcut: $shortcutPreviousSong)
                        ShortcutAssignerRow(title: "menu.increaseVolume", shortcut: $shortcutIncreaseVolume)
                        ShortcutAssignerRow(title: "menu.decreaseVolume", shortcut: $shortcutDecreaseVolume)
                        ShortcutAssignerRow(title: "menu.toggleMute", shortcut: $shortcutToggleMute)
                        ShortcutAssignerRow(title: "menu.shuffle", shortcut: $shortcutShuffle)
                        ShortcutAssignerRow(title: "menu.repeat", shortcut: $shortcutRepeat)
                    }

                    // MARK: - Reset Actions Section
                    // Card with a button to restore every shortcut to its factory default.
                    VStack(spacing: 0) {
                        HStack {
                            Text("Modify your controls above or revert back to standard layouts.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Reset Defaults") {
                                resetToDefaultBindings()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    .padding(.top, 5)
                }
                .padding(.horizontal)
                .padding(.top, 50)
                .padding(.bottom, 60)
            }
            .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 480, height: 460)
        .preferredColorScheme(appearanceManager.currentColorScheme())
    }

    // Builds a titled, card-styled group of shortcut rows (used for File,
    // Edit, View, and Controls groups in the Shortcuts tab).
    @ViewBuilder
    private func shortcutSection<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.accentColor)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }

    // Restores every shortcut @AppStorage value to its original factory default.
    private func resetToDefaultBindings() {
        shortcutNewPlaylist = "⌘N"
        shortcutImportMusic = "⌘O"
        shortcutImportPlaylist = "⌘⇧O"
        shortcutExportPlaylist = "⌘⇧E"
        shortcutDeletePlaylist = "⌫"
        shortcutFind = "⌘F"
        shortcutShowAsList = "⌘1"
        shortcutShowAsAlbums = "⌘2"
        shortcutShowAsCoverFlow = "⌘3"
        shortcutToggleUpNext = "⌘U"
        shortcutToggleLyrics = "⌘L"
        shortcutSwitchToMiniPlayer = "⌘⇧M"
        shortcutPlayPause = "Space"
        shortcutNextSong = "⌘→"
        shortcutPreviousSong = "⌘←"
        shortcutIncreaseVolume = "⌘↑"
        shortcutDecreaseVolume = "⌘↓"
        shortcutToggleMute = "⌘⇧↓"
        shortcutShuffle = "⌘S"
        shortcutRepeat = "⌘R"
    }

    // Returns the localized help text describing the currently selected
    // appearance mode (system/light/dark), shown beneath the appearance picker.
    private var helpText: String {
        switch appearanceManager.appAppearance {
        case "light": return NSLocalizedString("settings.appearanceHelp.light", comment: "")
        case "dark": return NSLocalizedString("settings.appearanceHelp.dark", comment: "")
        default: return NSLocalizedString("settings.appearanceHelp.system", comment: "")
        }
    }
}

// A single row in the Shortcuts tab: a label plus a button that, when
// clicked, starts "listening" mode and captures the next key combo pressed.
struct ShortcutAssignerRow: View {
    let title: LocalizedStringKey
    @Binding var shortcut: String
    // True while waiting for the user to press a new key combination.
    @State private var isListening = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.body)
                Spacer()
                Button(action: { isListening.toggle() }) {
                    // Shows "Press keys..." while listening, otherwise the
                    // currently assigned shortcut string.
                    Text(isListening ? "Press keys..." : shortcut)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 110)
                }
                .buttonStyle(.bordered)
                .tint(isListening ? .accentColor : .secondary)
                // Invisible helper view that installs/removes the actual
                // NSEvent key-down monitor used to capture the new shortcut.
                .background(ShortcutLocalMonitor(isListening: $isListening, shortcut: $shortcut))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider().padding(.leading, 10)
        }
    }
}

// An invisible NSView-backed helper that installs a local NSEvent monitor
// for key-down events while `isListening` is true, translates the captured
// key combo (modifiers + key) into a display string, and writes it into
// `shortcut`. This is the actual mechanism behind ShortcutAssignerRow's
// "click to record a new shortcut" behavior.
struct ShortcutLocalMonitor: NSViewRepresentable {
    @Binding var isListening: Bool
    @Binding var shortcut: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Ignore key events unless this row is actively listening.
                guard isListening else { return event }

                // Special-case Space and Delete/Backspace, which don't map
                // cleanly to a printable character via charactersIgnoringModifiers.
                if event.keyCode == 49 { // Space
                    shortcut = "Space"
                    isListening = false
                    return nil
                }
                if event.keyCode == 51 { // Delete/Backspace
                    shortcut = "⌫"
                    isListening = false
                    return nil
                }

                // Build the modifier-symbol prefix (⌘⇧⌥) for the recorded combo.
                var modifiers = ""
                if event.modifierFlags.contains(.command) { modifiers += "⌘" }
                if event.modifierFlags.contains(.shift) { modifiers += "⇧" }
                if event.modifierFlags.contains(.option) { modifiers += "⌥" }
                if event.modifierFlags.contains(.control) { modifiers += " Boot" }

                // Translate the pressed key into a display string, mapping
                // arrow-key function-key characters to arrow glyphs.
                var keyStr = event.charactersIgnoringModifiers ?? ""
                if let first = keyStr.first {
                    if first == Character(UnicodeScalar(NSUpArrowFunctionKey)!) { keyStr = "↑" }
                    else if first == Character(UnicodeScalar(NSDownArrowFunctionKey)!) { keyStr = "↓" }
                    else if first == Character(UnicodeScalar(NSLeftArrowFunctionKey)!) { keyStr = "←" }
                    else if first == Character(UnicodeScalar(NSRightArrowFunctionKey)!) { keyStr = "→" }
                }

                if !keyStr.isEmpty {
                    // Commit the new shortcut string and stop listening.
                    shortcut = "\(modifiers)\(keyStr.uppercased())"
                    isListening = false
                    return nil
                }
                // Not listening for a recognizable key — let the event pass through.
                return event
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
