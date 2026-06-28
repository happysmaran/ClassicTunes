import SwiftUI

// A small floating "mini player" window/panel: shows the current song's
// artwork, title/artist, transport controls (prev/play-pause/next), a close
// button, and a scrub bar with elapsed/remaining time labels.
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

    // True while the user is actively dragging the scrub slider; used to
    // avoid fighting with external playback-position updates mid-drag.
    @State private var isSeeking = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                // Song info capsule
                ZStack {
                    // Rounded "pill" background behind the song info/controls,
                    // styled with a soft green gradient reminiscent of classic iTunes.
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
                        .frame(height: 60)

                    if let song = selectedSong {
                        // Song is selected: show artwork, title/artist, and controls.
                        HStack(spacing: 12) {
                            // Album art
                            if let image = song.artworkImage {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                // Fallback placeholder when there's no artwork.
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray)
                                    .frame(width: 50, height: 50)
                            }

                            // Song info with truncation
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .font(.subheadline)
                                    .foregroundColor(Color.black.opacity(0.9))
                                    .shadow(color: .white.opacity(0.8), radius: 0.5, x: 0, y: 1)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Text(song.artist)
                                    .font(.caption2)
                                    .foregroundColor(Color.black.opacity(0.9))
                                    .shadow(color: .white.opacity(0.8), radius: 0.5, x: 0, y: 1)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(maxWidth: 180) // Limit width for proper truncation

                            Spacer()

                            // Controls
                            // Transport controls: previous / play-pause / next.
                            // Each button shares the same "glassy" circular
                            // background styling, varying only by icon/action.
                            HStack(spacing: 8) {
                                Button(action: onPrevious) {
                                    Image(systemName: "backward.fill")
                                        .padding(6)
                                        .background(
                                            Circle()
                                                .fill(colorScheme == .dark ?
                                                    AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) :
                                                    AnyShapeStyle(LinearGradient(
                                                        gradient: Gradient(colors: [
                                                            Color(nsColor: .controlBackgroundColor).opacity(0.95),
                                                            Color(nsColor: .separatorColor).opacity(0.25)
                                                        ]),
                                                        startPoint: .top,
                                                        endPoint: .bottom
                                                    ))
                                                )
                                                .overlay(
                                                    Circle()
                                                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.8)
                                                )
                                                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.25), radius: 1.5, x: 0, y: 1)
                                                .shadow(color: Color.white.opacity(colorScheme == .dark ? 0.05 : 0.2), radius: 0.5, x: 0, y: -0.5)
                                        )
                                        .foregroundColor(.primary)
                                }
                                .buttonStyle(PlainButtonStyle())

                                // Play/pause button — icon swaps based on isPlaying.
                                Button(action: onPlayPause) {
                                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                        .padding(6)
                                        .background(
                                            Circle()
                                                .fill(colorScheme == .dark ?
                                                    AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) :
                                                    AnyShapeStyle(LinearGradient(
                                                        gradient: Gradient(colors: [
                                                            Color(nsColor: .controlBackgroundColor).opacity(0.95),
                                                            Color(nsColor: .separatorColor).opacity(0.25)
                                                        ]),
                                                        startPoint: .top,
                                                        endPoint: .bottom
                                                    )
                                                ))
                                                .overlay(
                                                    Circle()
                                                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.8)
                                                )
                                                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.25), radius: 1.5, x: 0, y: 1)
                                                .shadow(color: Color.white.opacity(colorScheme == .dark ? 0.05 : 0.2), radius: 0.5, x: 0, y: -0.5)
                                        )
                                        .foregroundColor(.primary)
                                }
                                .buttonStyle(PlainButtonStyle())

                                Button(action: onNext) {
                                    Image(systemName: "forward.fill")
                                        .padding(6)
                                        .background(
                                            Circle()
                                                .fill(colorScheme == .dark ?
                                                    AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) :
                                                    AnyShapeStyle(LinearGradient(
                                                        gradient: Gradient(colors: [
                                                            Color(nsColor: .controlBackgroundColor).opacity(0.95),
                                                            Color(nsColor: .separatorColor).opacity(0.25)
                                                        ]),
                                                        startPoint: .top,
                                                        endPoint: .bottom
                                                    )
                                                ))
                                                .overlay(
                                                    Circle()
                                                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.8)
                                                )
                                                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.25), radius: 1.5, x: 0, y: 1)
                                                .shadow(color: Color.white.opacity(colorScheme == .dark ? 0.05 : 0.2), radius: 0.5, x: 0, y: -0.5)
                                        )
                                        .foregroundColor(.primary)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }

                            // Close button - consistent color regardless of mode
                            Button(action: onClose) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.gray)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.horizontal)
                    } else {
                        // No song selected: show a simple placeholder Apple logo.
                        HStack {
                            Spacer()
                            Image(systemName: "applelogo")
                                .font(.title)
                                .foregroundColor(.gray)
                            Spacer()
                        }
                    }
                }
            }
            .padding(.horizontal)

            // Progress bar
            // Only show the scrub bar / time labels once a song is loaded.
            if selectedSong != nil {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { playbackPosition },
                            set: { newValue in
                                // Mark as seeking while the user drags, and
                                // optimistically update the displayed position.
                                isSeeking = true
                                playbackPosition = newValue
                            }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            // When the drag ends, commit the seek via the callback.
                            if !editing {
                                onSeek(playbackPosition)
                                isSeeking = false
                            }
                        }
                    )
                    .disabled(playbackDuration <= 0)
                    .tint(Color.accentColor)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.3))
                            .frame(height: 4)
                    )
                    .frame(height: 4)

                    // Time labels
                    // Elapsed time (left) and total duration (right).
                    HStack {
                        Text(timeString(from: playbackPosition * playbackDuration))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(timeString(from: playbackDuration))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
            }
        }
        .frame(width: 400, height: 120)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
    }

    // Formats a duration in seconds as "M:SS" for display.
    private func timeString(from seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
