import SwiftUI
import AVFoundation

// A small floating "mini player" in the style of the classic iTunes MiniPlayer:
// a brushed-metal bar with round transport buttons on the left and an inset
// "LCD" display (artwork, title/artist, scrub bar and times) on the right.
// Accent colors come from the app's theme color.
struct MiniPlayerView: View {
    // Currently playing song (nil shows a placeholder Apple logo state).
    @Binding var selectedSong: Song?
    @Binding var isPlaying: Bool
    @Binding var volume: Double
    // Playback position is expressed as a 0...1 fraction of playbackDuration.
    @Binding var playbackPosition: Double
    @Binding var playbackDuration: Double

    // Action callbacks wired up by the parent/owner of this view.
    let onPlayPause: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSeek: (Double) -> Void
    let onClose: () -> Void

    // Custom initializer needed because the bindings are declared with
    // underscored backing storage (_selectedSong, etc.) for explicit wiring.
    init(
        selectedSong: Binding<Song?>,
        isPlaying: Binding<Bool>,
        volume: Binding<Double>,
        playbackPosition: Binding<Double>,
        playbackDuration: Binding<Double>,
        onPlayPause: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onSeek: @escaping (Double) -> Void,
        onClose: @escaping () -> Void
    ) {
        _selectedSong = selectedSong
        _isPlaying = isPlaying
        _volume = volume
        _playbackPosition = playbackPosition
        _playbackDuration = playbackDuration
        self.onPlayPause = onPlayPause
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onSeek = onSeek
        self.onClose = onClose
    }

    // True while the user is actively dragging the scrub bar; used to
    // avoid fighting with external playback-position updates mid-drag.
    @State private var isSeeking = false
    // Local mirror of `isPlaying` so the play/pause icon refreshes immediately.
    @State private var displayPlaying = false
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appearanceManager: AppearanceManager

    private var theme: Color { appearanceManager.themeColor }
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 12) {
            transportControls
            lcdDisplay
            closeButton
        }
        .padding(.horizontal, 12)
        .frame(width: 420, height: 72)
        .background(metalBackground)
        .tint(theme)
        .environment(\.themeColor, theme)
        .onAppear { displayPlaying = isPlaying }
        // Position ticks and song changes also resync the icon.
        .onChange(of: playbackPosition) { _ in displayPlaying = isPlaying }
        .onChange(of: selectedSong) { _ in displayPlaying = isPlaying }
    }

    // MARK: - Chrome

    // Brushed-metal bar, matching the app's light/dark chrome.
    private var metalBackground: some View {
        LinearGradient(
            colors: isDark
                ? [Color(white: 0.30), Color(white: 0.19)]
                : [Color(white: 0.93), Color(white: 0.78)],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(isDark ? 0.12 : 0.7))
                .frame(height: 1)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 6) {
            roundButton("backward.fill", action: onPrevious)
            roundButton(displayPlaying ? "pause.fill" : "play.fill") {
                onPlayPause()
                displayPlaying = isPlaying
            }
            roundButton("forward.fill", action: onNext)
        }
        .disabled(selectedSong == nil)
    }

    // Round transport button using the same styling as the main toolbar's playback buttons.
    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .padding(8)
                .background(
                    Circle()
                        .fill(buttonBackground)
                        .overlay(
                            Circle()
                                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.8)
                        )
                        .shadow(color: Color.black.opacity(isDark ? 0.3 : 0.25), radius: 1.5, x: 0, y: 1)
                        .shadow(color: Color.white.opacity(isDark ? 0.15 : 0.3), radius: 0.5, x: 0, y: -0.5)
                )
                .foregroundColor(.primary)
        }
        .buttonStyle(.plain)
    }

    private var buttonBackground: AnyShapeStyle {
        if isDark {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        } else {
            return AnyShapeStyle(LinearGradient(
                gradient: Gradient(colors: [
                    Color(nsColor: .controlBackgroundColor).opacity(0.95),
                    Color(nsColor: .separatorColor).opacity(0.25)
                ]),
                startPoint: .top,
                endPoint: .bottom
            ))
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - LCD display

    private var lcdDisplay: some View {
        HStack(spacing: 8) {
            if let song = selectedSong {
                artwork(for: song)
                VStack(spacing: 2) {
                    VStack(spacing: 0) {
                        Text(song.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.9))
                            .shadow(color: Color.black.opacity(isDark ? 0.4 : 0.1), radius: 0.5, x: 0, y: 1)
                            .lineLimit(1)
                        Text(song.artist)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.black.opacity(0.9))
                            .shadow(color: Color.black.opacity(isDark ? 0.4 : 0.1), radius: 0.5, x: 0, y: 1)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 6) {
                        Text(timeString(from: playbackPosition * playbackDuration))
                        scrubBar
                        Text("-" + timeString(from: max(playbackDuration - playbackPosition * playbackDuration, 0)))
                    }
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(Color.black.opacity(0.7))
                    .shadow(color: Color.black.opacity(isDark ? 0.4 : 0.1), radius: 0.5, x: 0, y: 1)
                }
            } else {
                Image(systemName: "applelogo")
                    .font(.title2)
                    .foregroundStyle(Color.gray)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        // Same green pill as the main window's now-playing display.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.88, green: 0.94, blue: 0.88),
                        Color(red: 0.76, green: 0.85, blue: 0.76)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.15), radius: 1, x: 0, y: 1)
        )
    }

    @ViewBuilder
    private func artwork(for song: Song) -> some View {
        Group {
            if let image = song.artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.4))
                    .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.35), lineWidth: 0.5))
    }

    private var scrubBar: some View {
        ThemedScrubBar(
            position: $playbackPosition,
            isEnabled: playbackDuration > 0,
            isSeeking: $isSeeking,
            onSeek: onSeek
        )
    }

    private func timeString(from seconds: Double) -> String {
        formatPlaybackTime(seconds)
    }
}

// Hosts the mini player and observes the engine so its bindings keep refreshing
// even though it lives in its own window outside the main view hierarchy.
struct MiniPlayerHost: View {
    @ObservedObject var engine: PlayerEngine
    let onClose: () -> Void

    var body: some View {
        MiniPlayerView(
            selectedSong: $engine.selectedSong,
            isPlaying: Binding(get: { (engine.player?.rate ?? 0) != 0 }, set: { shouldPlay in
                if shouldPlay { engine.play() } else { engine.pause() }
            }),
            volume: $engine.volume,
            playbackPosition: $engine.playbackPosition,
            playbackDuration: $engine.playbackDuration,
            onPlayPause: engine.togglePlayPause,
            onPrevious: engine.playPrevious,
            onNext: engine.playNext,
            onSeek: engine.handleSeek,
            onClose: onClose
        )
    }
}

// Thin Aqua-style progress bar filled with the theme color; click or drag to seek.
// Shared by the mini player and the main window's now-playing display.
struct ThemedScrubBar: View {
    @Binding var position: Double
    var isEnabled: Bool = true
    @Binding var isSeeking: Bool
    let onSeek: (Double) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(max(position, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.5 : 0.18))
                    .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                Capsule()
                    .fill(LinearGradient(
                        colors: [themeColor.shaded(0.4), themeColor],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .frame(width: max(proxy.size.width * fraction, 0))
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled, proxy.size.width > 0 else { return }
                        isSeeking = true
                        position = min(max(value.location.x / proxy.size.width, 0), 1)
                    }
                    .onEnded { _ in
                        // Commit the seek once the drag ends.
                        if isSeeking {
                            onSeek(position)
                            isSeeking = false
                        }
                    }
            )
        }
        .frame(height: 12)
    }
}

// Formats a duration in seconds as "M:SS" for display.
func formatPlaybackTime(_ seconds: Double) -> String {
    let totalSeconds = Int(seconds.isFinite ? max(seconds, 0) : 0)
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
}
