import SwiftUI
import AVKit

// A master controller utility bar containing playback management, hardware status tracking, and interface viewport toggles.
struct TopToolbarView: View {
    // MARK: - Navigation & View Binding Mappings
    @Binding var isAlbumView: Bool
    @Binding var selectedSong: Song?
    @Binding var isPlaying: Bool
    
    // Trigger action running back-channel track operations to pull up the previous playlist entry.
    var playPrevious: () -> Void
    // Trigger action running forward-channel track operations to skip onto the upcoming queue entry.
    var playNext: () -> Void
    
    // MARK: - Audio Properties
    @Binding var volume: Double
    @Binding var playbackPosition: Double
    @Binding var playbackDuration: Double
    
    // Dynamic adjustment worker syncing position seek changes directly into core player lines.
    var onSeek: (Double) -> Void
    @Binding var isSeeking: Bool
    
    // MARK: - Queue Modification Flags
    @Binding var isShuffleEnabled: Bool
    @Binding var isRepeatEnabled: Bool
    @Binding var isRepeatOne: Bool
    @Binding var isStopped: Bool
    @Binding var isCoverFlowActive: Bool
    
    // Secondary container callback used to pop open detached lightweight desktop widget layouts.
    var onMiniPlayerToggle: (() -> Void)? = nil
    
    // MARK: - Input Utilities
    @Binding var searchText: String
    var searchFieldFocus: FocusState<Bool>.Binding

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            playbackControlsGroup
            volumeControl
            nowPlayingView
            viewToggleButtons
            searchField
        }
        .padding(.top, 24)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .background(toolbarBackground)
        .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
        .foregroundColor(.primary)
    }

    // MARK: - Transport Control Subviews
    private var playbackControlsGroup: some View {
        HStack(spacing: 8) {
            playbackButton(icon: "backward.fill", action: playPrevious)
            playbackButton(icon: isPlaying ? "pause.fill" : "play.fill") {
                isPlaying.toggle()
            }
            playbackButton(icon: "stop.fill") {
                isPlaying = false
                isStopped = true
            }
            playbackButton(icon: "forward.fill", action: playNext)
        }
    }

    private var volumeControl: some View {
        Slider(value: Binding(
            get: { volume },
            set: { volume = $0 }
        ), in: 0...1)
            .frame(width: 100)
            .onChange(of: volume) { _ in
                // Magic-number indicator downstream notifying active audio pipelines to recalibrate decibel rails
                onSeek(-1)
            }
    }

    // MARK: - Center LCD Display Frame
    private var nowPlayingView: some View {
        ZStack {
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
                .frame(height: 56)

            if let song = selectedSong, isPlaying || !isStopped {
                songInfoView(song)
            } else {
                Image("Icon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .saturation(0)
                    .opacity(0.9)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .contextMenu {
            Button("miniPlayer.openIn") {
                onMiniPlayerToggle?()
            }
        }
    }

    private func songInfoView(_ song: Song) -> some View {
        VStack(spacing: 2) {
            Text(song.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color.black.opacity(0.9))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.1), radius: 0.5, x: 0, y: 1)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240)

            AnimatedLabel(texts: [song.artist, song.album])
                .font(.caption2)
                .foregroundColor(Color.black.opacity(0.9))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.1), radius: 0.5, x: 0, y: 1)
                .lineLimit(1)
                .truncationMode(.tail)

            // Elapsed time, scrub bar and remaining time, as in the mini player.
            HStack(spacing: 6) {
                Text(formatPlaybackTime(playbackPosition * playbackDuration))
                ThemedScrubBar(
                    position: $playbackPosition,
                    isEnabled: playbackDuration > 0,
                    isSeeking: $isSeeking,
                    onSeek: onSeek
                )
                Text("-" + formatPlaybackTime(playbackDuration - playbackPosition * playbackDuration))
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundColor(Color.black.opacity(0.7))
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.1), radius: 0.5, x: 0, y: 1)
            .frame(width: 280)
            .padding(.top, 2)
        }
        .padding(.horizontal)
    }

    // MARK: - View Mode & Utility Subviews
    private var viewToggleButtons: some View {
        HStack(spacing: 6) {
            toggleButton(icon: "list.bullet", isActive: !isAlbumView && !isCoverFlowActive) {
                isAlbumView = false
                isCoverFlowActive = false
            }
            toggleButton(icon: "square.grid.2x2", isActive: isAlbumView) {
                isAlbumView = true
                isCoverFlowActive = false
            }
            toggleButton(icon: "square.stack.3d.down.forward", isActive: isCoverFlowActive) {
                isCoverFlowActive = true
                isAlbumView = false
            }
            toggleButton(icon: "shuffle", isActive: isShuffleEnabled) { isShuffleEnabled.toggle() }
            RepeatButton(isRepeatAll: $isRepeatEnabled, isRepeatOne: $isRepeatOne)
        }
    }

    private var searchField: some View {
        TextField("toolbar.search", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
            .focused(searchFieldFocus)
    }

    // MARK: - Styling & Button Builders
    private var toolbarBackground: some View {
        let isDark = colorScheme == .dark
        let gradientColors: [Color] = isDark
            ? [Color(white: 0.34), Color(white: 0.24), Color(white: 0.18)]
            : [Color(white: 0.93), Color(white: 0.80), Color(white: 0.70)]

        return ZStack {
            LinearGradient(colors: gradientColors, startPoint: .top, endPoint: .bottom)
            LinearGradient(
                colors: [Color.white.opacity(isDark ? 0.08 : 0.35), Color.white.opacity(0)],
                startPoint: .top,
                endPoint: .center
            )
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(isDark ? 0.25 : 0.7)).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(isDark ? 0.6 : 0.4)).frame(height: 1)
        }
    }

    private func playbackButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .padding(8)
                .background(
                    Circle()
                        .fill(buttonBackground)
                        .overlay(
                            Circle()
                                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.8)
                        )
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.25), radius: 1.5, x: 0, y: 1)
                        .shadow(color: Color.white.opacity(colorScheme == .dark ? 0.15 : 0.3), radius: 0.5, x: 0, y: -0.5)
                )
                .foregroundColor(.primary)
        }
        .buttonStyle(.plain)
    }

    private var buttonBackground: AnyShapeStyle {
        if colorScheme == .dark {
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

    private func toggleButton(icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.gray))
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Companion Controls

// A standalone interface button designed to cycle state parameters seamlessly through unified repeating audio paradigms.
struct RepeatButton: View {
    @Binding var isRepeatAll: Bool
    @Binding var isRepeatOne: Bool

    var body: some View {
        Button(action: cycleRepeatMode) {
            Group {
                if isRepeatOne {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "repeat")
                            .foregroundStyle(.tint)
                        Text("1")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .offset(x: 2, y: 2)
                    }
                } else if isRepeatAll {
                    Image(systemName: "repeat")
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "repeat")
                        .foregroundColor(.gray)
                }
            }
        }
        .buttonStyle(.borderless)
    }

    // Progresses loop patterns sequentially between Off, Loop All, and Loop Single Item track constraints.
    private func cycleRepeatMode() {
        if !isRepeatAll && !isRepeatOne {
            isRepeatAll = true
            isRepeatOne = false
        } else if isRepeatAll && !isRepeatOne {
            isRepeatAll = false
            isRepeatOne = true
        } else {
            isRepeatAll = false
            isRepeatOne = false
        }
    }
}
