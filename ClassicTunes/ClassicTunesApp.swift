import SwiftUI

// MARK: - Focused values used to wire menu commands to whichever window/scene is focused.
// Each action is published from ContentView via `.focusedSceneValue(...)` and consumed
// by the Commands structs below.

private struct DeletePlaylistActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct NewPlaylistActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct ImportMusicActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct ImportPlaylistActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct ExportPlaylistActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct FocusSearchFieldActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct ShowListViewActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct ShowAlbumGridActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct ShowCoverFlowActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct ToggleUpNextActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct ShowUpNextValueKey: FocusedValueKey {
    typealias Value = Bool
}
private struct ToggleLyricsActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct ShowLyricsValueKey: FocusedValueKey {
    typealias Value = Bool
}
private struct ToggleMiniPlayerActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct TogglePlayPauseActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct IsPlayingValueKey: FocusedValueKey {
    typealias Value = Bool
}
private struct PlayNextActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct PlayPreviousActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct IncreaseVolumeActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct DecreaseVolumeActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct ToggleMuteActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct IsMutedValueKey: FocusedValueKey {
    typealias Value = Bool
}
private struct ToggleShuffleActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct IsShuffleValueKey: FocusedValueKey {
    typealias Value = Bool
}
private struct CycleRepeatModeActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct IsRepeatAllValueKey: FocusedValueKey {
    typealias Value = Bool
}
private struct IsRepeatOneValueKey: FocusedValueKey {
    typealias Value = Bool
}
private struct ShowKeyboardShortcutsActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var deletePlaylistAction: (() -> Void)? {
        get { self[DeletePlaylistActionKey.self] }
        set { self[DeletePlaylistActionKey.self] = newValue }
    }
    var newPlaylistAction: (() -> Void)? {
        get { self[NewPlaylistActionKey.self] }
        set { self[NewPlaylistActionKey.self] = newValue }
    }
    var importMusicAction: (() -> Void)? {
        get { self[ImportMusicActionKey.self] }
        set { self[ImportMusicActionKey.self] = newValue }
    }
    var importPlaylistAction: (() -> Void)? {
        get { self[ImportPlaylistActionKey.self] }
        set { self[ImportPlaylistActionKey.self] = newValue }
    }
    var exportPlaylistAction: (() -> Void)? {
        get { self[ExportPlaylistActionKey.self] }
        set { self[ExportPlaylistActionKey.self] = newValue }
    }
    var focusSearchFieldAction: (() -> Void)? {
        get { self[FocusSearchFieldActionKey.self] }
        set { self[FocusSearchFieldActionKey.self] = newValue }
    }
    var showListViewAction: (() -> Void)? {
        get { self[ShowListViewActionKey.self] }
        set { self[ShowListViewActionKey.self] = newValue }
    }
    var showAlbumGridAction: (() -> Void)? {
        get { self[ShowAlbumGridActionKey.self] }
        set { self[ShowAlbumGridActionKey.self] = newValue }
    }
    var showCoverFlowAction: (() -> Void)? {
        get { self[ShowCoverFlowActionKey.self] }
        set { self[ShowCoverFlowActionKey.self] = newValue }
    }
    var toggleUpNextAction: (() -> Void)? {
        get { self[ToggleUpNextActionKey.self] }
        set { self[ToggleUpNextActionKey.self] = newValue }
    }
    var showUpNextValue: Bool? {
        get { self[ShowUpNextValueKey.self] }
        set { self[ShowUpNextValueKey.self] = newValue }
    }
    var toggleLyricsAction: (() -> Void)? {
        get { self[ToggleLyricsActionKey.self] }
        set { self[ToggleLyricsActionKey.self] = newValue }
    }
    var showLyricsValue: Bool? {
        get { self[ShowLyricsValueKey.self] }
        set { self[ShowLyricsValueKey.self] = newValue }
    }
    var toggleMiniPlayerAction: (() -> Void)? {
        get { self[ToggleMiniPlayerActionKey.self] }
        set { self[ToggleMiniPlayerActionKey.self] = newValue }
    }
    var togglePlayPauseAction: (() -> Void)? {
        get { self[TogglePlayPauseActionKey.self] }
        set { self[TogglePlayPauseActionKey.self] = newValue }
    }
    var isPlayingValue: Bool? {
        get { self[IsPlayingValueKey.self] }
        set { self[IsPlayingValueKey.self] = newValue }
    }
    var playNextAction: (() -> Void)? {
        get { self[PlayNextActionKey.self] }
        set { self[PlayNextActionKey.self] = newValue }
    }
    var playPreviousAction: (() -> Void)? {
        get { self[PlayPreviousActionKey.self] }
        set { self[PlayPreviousActionKey.self] = newValue }
    }
    var increaseVolumeAction: (() -> Void)? {
        get { self[IncreaseVolumeActionKey.self] }
        set { self[IncreaseVolumeActionKey.self] = newValue }
    }
    var decreaseVolumeAction: (() -> Void)? {
        get { self[DecreaseVolumeActionKey.self] }
        set { self[DecreaseVolumeActionKey.self] = newValue }
    }
    var toggleMuteAction: (() -> Void)? {
        get { self[ToggleMuteActionKey.self] }
        set { self[ToggleMuteActionKey.self] = newValue }
    }
    var isMutedValue: Bool? {
        get { self[IsMutedValueKey.self] }
        set { self[IsMutedValueKey.self] = newValue }
    }
    var toggleShuffleAction: (() -> Void)? {
        get { self[ToggleShuffleActionKey.self] }
        set { self[ToggleShuffleActionKey.self] = newValue }
    }
    var isShuffleValue: Bool? {
        get { self[IsShuffleValueKey.self] }
        set { self[IsShuffleValueKey.self] = newValue }
    }
    var cycleRepeatModeAction: (() -> Void)? {
        get { self[CycleRepeatModeActionKey.self] }
        set { self[CycleRepeatModeActionKey.self] = newValue }
    }
    var isRepeatAllValue: Bool? {
        get { self[IsRepeatAllValueKey.self] }
        set { self[IsRepeatAllValueKey.self] = newValue }
    }
    var isRepeatOneValue: Bool? {
        get { self[IsRepeatOneValueKey.self] }
        set { self[IsRepeatOneValueKey.self] = newValue }
    }
    var showKeyboardShortcutsAction: (() -> Void)? {
        get { self[ShowKeyboardShortcutsActionKey.self] }
        set { self[ShowKeyboardShortcutsActionKey.self] = newValue }
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
            FileCommands()
            EditCommands()
            ViewCommands()
            ControlsCommands()
            HelpCommands()
        }

        Settings {
            SettingsView()
                .frame(minWidth: 480, minHeight: 200)
                .environmentObject(appearanceManager)
        }
    }
}

// MARK: - File menu

struct FileCommands: Commands {
    @FocusedValue(\.newPlaylistAction) private var newPlaylistAction: (() -> Void)?
    @FocusedValue(\.importMusicAction) private var importMusicAction: (() -> Void)?
    @FocusedValue(\.importPlaylistAction) private var importPlaylistAction: (() -> Void)?
    @FocusedValue(\.exportPlaylistAction) private var exportPlaylistAction: (() -> Void)?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("menu.newPlaylist") {
                newPlaylistAction?()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(newPlaylistAction == nil)

            Divider()

            Button("menu.importMusic") {
                importMusicAction?()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(importMusicAction == nil)

            Button("menu.importPlaylist") {
                importPlaylistAction?()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(importPlaylistAction == nil)

            Button("menu.exportPlaylist") {
                exportPlaylistAction?()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(exportPlaylistAction == nil)
        }
    }
}

// MARK: - Edit menu

struct EditCommands: Commands {
    @FocusedValue(\.deletePlaylistAction) private var deleteAction: (() -> Void)?
    @FocusedValue(\.focusSearchFieldAction) private var focusSearchFieldAction: (() -> Void)?

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("menu.find") {
                focusSearchFieldAction?()
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(focusSearchFieldAction == nil)

            Button("menu.deletePlaylist") {
                deleteAction?()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(deleteAction == nil)
        }
    }
}

// MARK: - View menu

struct ViewCommands: Commands {
    @FocusedValue(\.showListViewAction) private var showListViewAction: (() -> Void)?
    @FocusedValue(\.showAlbumGridAction) private var showAlbumGridAction: (() -> Void)?
    @FocusedValue(\.showCoverFlowAction) private var showCoverFlowAction: (() -> Void)?
    @FocusedValue(\.toggleUpNextAction) private var toggleUpNextAction: (() -> Void)?
    @FocusedValue(\.showUpNextValue) private var showUpNextValue: Bool?
    @FocusedValue(\.toggleLyricsAction) private var toggleLyricsAction: (() -> Void)?
    @FocusedValue(\.showLyricsValue) private var showLyricsValue: Bool?
    @FocusedValue(\.toggleMiniPlayerAction) private var toggleMiniPlayerAction: (() -> Void)?

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("menu.showAsList") {
                showListViewAction?()
            }
            .keyboardShortcut("1", modifiers: [.command])
            .disabled(showListViewAction == nil)

            Button("menu.showAsAlbums") {
                showAlbumGridAction?()
            }
            .keyboardShortcut("2", modifiers: [.command])
            .disabled(showAlbumGridAction == nil)

            Button("menu.showAsCoverFlow") {
                showCoverFlowAction?()
            }
            .keyboardShortcut("3", modifiers: [.command])
            .disabled(showCoverFlowAction == nil)

            Divider()

            Button((showUpNextValue ?? false) ? "menu.hideUpNext" : "menu.showUpNext") {
                toggleUpNextAction?()
            }
            .keyboardShortcut("u", modifiers: [.command])
            .disabled(toggleUpNextAction == nil)

            Button((showLyricsValue ?? false) ? "menu.hideLyrics" : "menu.showLyrics") {
                toggleLyricsAction?()
            }
            .keyboardShortcut("l", modifiers: [.command])
            .disabled(toggleLyricsAction == nil)

            Divider()

            Button("menu.switchToMiniPlayer") {
                toggleMiniPlayerAction?()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(toggleMiniPlayerAction == nil)
        }
    }
}

// MARK: - Controls menu

struct ControlsCommands: Commands {
    @FocusedValue(\.togglePlayPauseAction) private var togglePlayPauseAction: (() -> Void)?
    @FocusedValue(\.isPlayingValue) private var isPlayingValue: Bool?
    @FocusedValue(\.playNextAction) private var playNextAction: (() -> Void)?
    @FocusedValue(\.playPreviousAction) private var playPreviousAction: (() -> Void)?
    @FocusedValue(\.increaseVolumeAction) private var increaseVolumeAction: (() -> Void)?
    @FocusedValue(\.decreaseVolumeAction) private var decreaseVolumeAction: (() -> Void)?
    @FocusedValue(\.toggleMuteAction) private var toggleMuteAction: (() -> Void)?
    @FocusedValue(\.isMutedValue) private var isMutedValue: Bool?
    @FocusedValue(\.toggleShuffleAction) private var toggleShuffleAction: (() -> Void)?
    @FocusedValue(\.isShuffleValue) private var isShuffleValue: Bool?
    @FocusedValue(\.cycleRepeatModeAction) private var cycleRepeatModeAction: (() -> Void)?
    @FocusedValue(\.isRepeatAllValue) private var isRepeatAllValue: Bool?
    @FocusedValue(\.isRepeatOneValue) private var isRepeatOneValue: Bool?

    private var repeatLabel: LocalizedStringKey {
        if isRepeatOneValue == true { return "menu.repeatOne" }
        if isRepeatAllValue == true { return "menu.repeatOff" }
        return "menu.repeatAll"
    }

    var body: some Commands {
        CommandMenu("menu.controls") {
            Button((isPlayingValue ?? false) ? "menu.pause" : "menu.play") {
                togglePlayPauseAction?()
            }
            .keyboardShortcut(" ", modifiers: [])
            .disabled(togglePlayPauseAction == nil)

            Divider()

            Button("menu.nextSong") {
                playNextAction?()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            .disabled(playNextAction == nil)

            Button("menu.previousSong") {
                playPreviousAction?()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            .disabled(playPreviousAction == nil)

            Divider()

            Button("menu.increaseVolume") {
                increaseVolumeAction?()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(increaseVolumeAction == nil)

            Button("menu.decreaseVolume") {
                decreaseVolumeAction?()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .disabled(decreaseVolumeAction == nil)

            Button((isMutedValue ?? false) ? "menu.unmute" : "menu.mute") {
                toggleMuteAction?()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
            .disabled(toggleMuteAction == nil)

            Divider()

            Button("menu.shuffle") {
                toggleShuffleAction?()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(toggleShuffleAction == nil)

            Button(repeatLabel) {
                cycleRepeatModeAction?()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(cycleRepeatModeAction == nil)
        }
    }
}

// MARK: - Help menu

struct HelpCommands: Commands {
    @FocusedValue(\.showKeyboardShortcutsAction) private var showKeyboardShortcutsAction: (() -> Void)?

    var body: some Commands {
        CommandGroup(after: .help) {
            Divider()
            Button("menu.keyboardShortcuts") {
                showKeyboardShortcutsAction?()
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
            .disabled(showKeyboardShortcutsAction == nil)
        }
    }
}
