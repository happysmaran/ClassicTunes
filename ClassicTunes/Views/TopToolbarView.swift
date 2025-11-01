import SwiftUI
import AVKit

struct TopToolbarView: View {
    @Binding var isAlbumView: Bool
    @Binding var showFileImporter: Bool
    @Binding var selectedSong: Song?
    @Binding var isPlaying: Bool
    var playPrevious: () -> Void
    var playNext: () -> Void
    @Binding var volume: Double
    @Binding var playbackPosition: Double
    @Binding var playbackDuration: Double
    var onSeek: (Double) -> Void
    @Binding var isSeeking: Bool
    @Binding var isShuffleEnabled: Bool
    @Binding var isRepeatEnabled: Bool  // This represents repeat all
    @Binding var isRepeatOne: Bool      // Added this parameter
    @Binding var isStopped: Bool

    var body: some View {
        HStack(spacing: 12) {
            playbackControlsGroup
            volumeControl
            nowPlayingView
            viewToggleButtons
            searchAndImportGroup
        }
        .padding(.top, 24)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .background(toolbarBackground)
        .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
        .foregroundColor(.black)
    }
    
    private var playbackControlsGroup: some View {
        HStack(spacing: 8) {
            playbackButton(icon: "backward.fill", action: playPrevious)
            playbackButton(icon: isPlaying ? "pause.fill" : "play.fill") {
                isPlaying.toggle()
                if isPlaying { isStopped = false }
            }
            playbackButton(icon: "stop.fill") {
                isPlaying = false
                isStopped = true
                selectedSong = nil
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
            .onChange(of: volume) { newVolume in
                onSeek(-1)
            }
    }
    
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
                        .stroke(Color(NSColor(calibratedWhite: 0.6, alpha: 1.0)), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.15), radius: 1, x: 0, y: 1)
                .frame(height: 56)

            if let song = selectedSong, isPlaying || !isStopped {
                songInfoView(song)
            } else {
                Image(systemName: "applelogo")
                    .font(.title)
                    .foregroundColor(.gray)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
    
    private func songInfoView(_ song: Song) -> some View {
        VStack(spacing: 2) {
            Text(song.title)
                .font(.subheadline)
                .foregroundColor(.black)
                .shadow(color: .white.opacity(0.8), radius: 0.5, x: 0, y: 1)

            AnimatedLabel(texts: [song.artist, song.album])
                .font(.caption2)
                .foregroundColor(.black)
                .shadow(color: .white.opacity(0.8), radius: 0.5, x: 0, y: 1)

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
            .frame(width: 280)
            .tint(Color.gray)
            .frame(height: 4)
            .padding(.top, 4)
        }
        .padding(.horizontal)
    }
    
    private var viewToggleButtons: some View {
        HStack(spacing: 6) {
            toggleButton(icon: "list.bullet", isActive: !isAlbumView) { isAlbumView = false }
            toggleButton(icon: "square.grid.2x2", isActive: isAlbumView) { isAlbumView = true }
            toggleButton(icon: "shuffle", isActive: isShuffleEnabled) { isShuffleEnabled.toggle() }
            RepeatButton(isRepeatAll: $isRepeatEnabled, isRepeatOne: $isRepeatOne)  // Updated repeat button
        }
    }
    
    private var searchAndImportGroup: some View {
        HStack {
            TextField("Search", text: .constant(""))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)

            Button("Import Music") {
                showFileImporter = true
            }
        }
    }
    
    private var toolbarBackground: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                Color.white,
                Color(NSColor(calibratedWhite: 0.85, alpha: 1.0))
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    private func playbackButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .padding(8)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [.white.opacity(0.7), .gray.opacity(0.4)]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
    
    private func toggleButton(icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundColor(isActive ? .accentColor : .gray)
        }
        .buttonStyle(.borderless)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.5))
        )
    }
}

// New RepeatButton view to handle the cycling behavior
struct RepeatButton: View {
    @Binding var isRepeatAll: Bool
    @Binding var isRepeatOne: Bool

    var body: some View {
        Button(action: cycleRepeatMode) {
            Group {
                if isRepeatOne {
                    // Show repeat one icon with small '1' badge
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "repeat")
                            .foregroundColor(.accentColor)
                        Text("1")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                            .offset(x: 2, y: 2)
                    }
                } else if isRepeatAll {
                    // Show regular repeat icon
                    Image(systemName: "repeat")
                        .foregroundColor(.accentColor)
                } else {
                    // Show disabled repeat icon
                    Image(systemName: "repeat")
                        .foregroundColor(.gray)
                }
            }
        }
        .buttonStyle(.borderless)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.5))
        )
    }
    
    private func cycleRepeatMode() {
        if !isRepeatAll && !isRepeatOne {
            // Currently off -> Enable repeat all
            isRepeatAll = true
            isRepeatOne = false
        } else if isRepeatAll && !isRepeatOne {
            // Currently repeat all -> Enable repeat one
            isRepeatAll = false
            isRepeatOne = true
        } else {
            // Currently repeat one -> Disable repeat
            isRepeatAll = false
            isRepeatOne = false
        }
    }
}
