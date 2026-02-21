import SwiftUI
import AVKit

struct MiniPlayerView: View {
    let player: AVPlayer?
    @Binding var selectedSong: Song?
    @Binding var isPlaying: Bool
    @Binding var volume: Double
    @Binding var playbackPosition: Double
    @Binding var playbackDuration: Double

    let onPlayPause: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSeek: (Double) -> Void
    let onClose: () -> Void

    init(
        player: AVPlayer?,
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
        self.player = player
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

    @State private var isSeeking = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                // Song info capsule
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
                        .frame(height: 60)

                    if let song = selectedSong {
                        HStack(spacing: 12) {
                            // Album art
                            if let image = song.artworkImage {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
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
            if selectedSong != nil {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { playbackPosition },
                            set: { newValue in
                                isSeeking = true
                                playbackPosition = newValue
                            }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
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

    private func timeString(from seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
