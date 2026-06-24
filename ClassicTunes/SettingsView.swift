import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appearanceManager: AppearanceManager
    @AppStorage("albumGridBackgroundStyle") private var albumGridBackgroundStyle: String = "dark"
    
    // todo
    @AppStorage("isCrossfadeEnabled") private var isCrossfadeEnabled: Bool = false
    @AppStorage("crossfadeDuration") private var crossfadeDuration: Double = 6.0
    @AppStorage("isSoundEnhancerEnabled") private var isSoundEnhancerEnabled: Bool = false
    @AppStorage("soundEnhancerIntensity") private var soundEnhancerIntensity: Double = 5.0
    
    @AppStorage("shortcut.newPlaylist") private var shortcutNewPlaylist: String = "⌘N"
    @AppStorage("shortcut.importMusic") private var shortcutImportMusic: String = "⌘O"
    @AppStorage("shortcut.importPlaylist") private var shortcutImportPlaylist: String = "⌘⇧O"
    @AppStorage("shortcut.exportPlaylist") private var shortcutExportPlaylist: String = "⌘⇧E"
    
    @AppStorage("shortcut.deletePlaylist") private var shortcutDeletePlaylist: String = "⌫"
    @AppStorage("shortcut.find") private var shortcutFind: String = "⌘F"
    
    @AppStorage("shortcut.showAsList") private var shortcutShowAsList: String = "⌘1"
    @AppStorage("shortcut.showAsAlbums") private var shortcutShowAsAlbums: String = "⌘2"
    @AppStorage("shortcut.showAsCoverFlow") private var shortcutShowAsCoverFlow: String = "⌘3"
    @AppStorage("shortcut.toggleUpNext") private var shortcutToggleUpNext: String = "⌘U"
    @AppStorage("shortcut.toggleLyrics") private var shortcutToggleLyrics: String = "⌘L"
    @AppStorage("shortcut.switchToMiniPlayer") private var shortcutSwitchToMiniPlayer: String = "⌘⇧M"
    
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
                    Picker("settings.appAppearance", selection: $appearanceManager.appAppearance) {
                        Text("settings.system").tag("system")
                        Text("settings.light").tag("light")
                        Text("settings.dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appearanceManager.appAppearance) { _ in
                        appearanceManager.applyAppearance()
                    }

                    Text(helpText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(height: 40, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Section(header: Text("settings.albumGrid")) {
                    Picker("settings.albumGrid.background", selection: $albumGridBackgroundStyle) {
                        Text("settings.light").tag("light")
                        Text("settings.dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }
            
            // MARK: - Playback Tab
            // todo
            Form {
                Section(header: Text("Audio Effects")) {
                    Toggle("Crossfade Songs", isOn: $isCrossfadeEnabled)
                    HStack {
                        Slider(value: $crossfadeDuration, in: 1...12, step: 1)
                            .disabled(!isCrossfadeEnabled)
                        Text("\(Int(crossfadeDuration)) secs").frame(width: 50, alignment: .trailing)
                    }
                    
                    Toggle("Sound Enhancer", isOn: $isSoundEnhancerEnabled)
                    HStack {
                        Text("Low").font(.caption)
                        Slider(value: $soundEnhancerIntensity, in: 1...10, step: 1).disabled(!isSoundEnhancerEnabled)
                        Text("High").font(.caption)
                    }
                }
            }
            .padding()
            .tabItem { Label("Playback", systemImage: "play.circle") }
            
            // MARK: - Shortcuts Tab
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

    private var helpText: String {
        switch appearanceManager.appAppearance {
        case "light": return NSLocalizedString("settings.appearanceHelp.light", comment: "")
        case "dark": return NSLocalizedString("settings.appearanceHelp.dark", comment: "")
        default: return NSLocalizedString("settings.appearanceHelp.system", comment: "")
        }
    }
}

struct ShortcutAssignerRow: View {
    let title: LocalizedStringKey
    @Binding var shortcut: String
    @State private var isListening = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.body)
                Spacer()
                Button(action: { isListening.toggle() }) {
                    Text(isListening ? "Press keys..." : shortcut)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 110)
                }
                .buttonStyle(.bordered)
                .tint(isListening ? .accentColor : .secondary)
                .background(ShortcutLocalMonitor(isListening: $isListening, shortcut: $shortcut))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            
            Divider().padding(.leading, 10)
        }
    }
}

struct ShortcutLocalMonitor: NSViewRepresentable {
    @Binding var isListening: Bool
    @Binding var shortcut: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard isListening else { return event }
                
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
                
                var modifiers = ""
                if event.modifierFlags.contains(.command) { modifiers += "⌘" }
                if event.modifierFlags.contains(.shift) { modifiers += "⇧" }
                if event.modifierFlags.contains(.option) { modifiers += "⌥" }
                if event.modifierFlags.contains(.control) { modifiers += " Boot" }
                
                var keyStr = event.charactersIgnoringModifiers ?? ""
                if let first = keyStr.first {
                    if first == Character(UnicodeScalar(NSUpArrowFunctionKey)!) { keyStr = "↑" }
                    else if first == Character(UnicodeScalar(NSDownArrowFunctionKey)!) { keyStr = "↓" }
                    else if first == Character(UnicodeScalar(NSLeftArrowFunctionKey)!) { keyStr = "←" }
                    else if first == Character(UnicodeScalar(NSRightArrowFunctionKey)!) { keyStr = "→" }
                }
                
                if !keyStr.isEmpty {
                    shortcut = "\(modifiers)\(keyStr.uppercased())"
                    isListening = false
                    return nil
                }
                return event
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
