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
                                .stroke(Color.gray, lineWidth: 1) // Changed from system color to fixed gray
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
                            
                            // Song info
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .font(.subheadline)
                                    .foregroundColor(.black) // Ensure black text
                                    .shadow(color: .white.opacity(0.8), radius: 0.5, x: 0, y: 1)
                                    .lineLimit(1)

                                Text(song.artist)
                                    .font(.caption2)
                                    .foregroundColor(.black) // Ensure black text
                                    .shadow(color: .white.opacity(0.8), radius: 0.5, x: 0, y: 1)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            // Controls
                            HStack(spacing: 8) {
                                Button(action: onPrevious) {
                                    Image(systemName: "backward.fill")
                                        .padding(6)
                                        .background(
                                            Circle()
                                                .fill(
                                                    LinearGradient(
                                                        gradient: Gradient(colors: [.white.opacity(0.7), Color.gray.opacity(0.4)]),
                                                        startPoint: .top,
                                                        endPoint: .bottom
                                                    )
                                                )
                                        )
                                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                                        .foregroundColor(.black) // Ensure black icons
                                }
                                .buttonStyle(PlainButtonStyle())

                                Button(action: onPlayPause) {
                                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                        .padding(6)
                                        .background(
                                            Circle()
                                                .fill(
                                                    LinearGradient(
                                                        gradient: Gradient(colors: [.white.opacity(0.7), Color.gray.opacity(0.4)]),
                                                        startPoint: .top,
                                                        endPoint: .bottom
                                                    )
                                                )
                                        )
                                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                                        .foregroundColor(.black) // Ensure black icons
                                }
                                .buttonStyle(PlainButtonStyle())

                                Button(action: onNext) {
                                    Image(systemName: "forward.fill")
                                        .padding(6)
                                        .background(
                                            Circle()
                                                .fill(
                                                    LinearGradient(
                                                        gradient: Gradient(colors: [.white.opacity(0.7), Color.gray.opacity(0.4)]),
                                                        startPoint: .top,
                                                        endPoint: .bottom
                                                    )
                                                )
                                        )
                                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                                        .foregroundColor(.black) // Ensure black icons
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            
                            // Close button
                            Button(action: onClose) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.gray) // Fixed gray instead of system secondary
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
                    .tint(Color.gray) // Fixed gray instead of system tint
                    .frame(height: 4)
                    
                    // Time labels
                    HStack {
                        Text(timeString(from: playbackPosition * playbackDuration))
                            .font(.caption2)
                            .foregroundColor(.gray) // Fixed gray instead of system secondary
                        Spacer()
                        Text(timeString(from: playbackDuration))
                            .font(.caption2)
                            .foregroundColor(.gray) // Fixed gray instead of system secondary
                    }
                }
                .padding(.horizontal)
            }
        }
        .frame(width: 400, height: 120)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.white, // Fixed white instead of system color
                    Color(red: 0.85, green: 0.85, blue: 0.85) // Fixed gray instead of system color
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
        .colorScheme(.light) // Force light mode in the mini player
        .preferredColorScheme(.light) // Additional enforcement
    }
    
    private func timeString(from seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
