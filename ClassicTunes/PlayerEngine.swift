import Foundation
import AVFoundation
import MediaPlayer
import AppKit
import Combine
import CoreAudio

/// Owns all audio-playback state and logic for the app as a single,
/// process-lifetime singleton, instead of the older state living in
/// `ContentView`'s `@State`.
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine()

    // MARK: - Published UI-facing state

    @Published var player: AVPlayer?
    @Published var selectedSong: Song?
    @Published var playbackPosition: Double = 0.0
    @Published var playbackDuration: Double = 1.0
    @Published var upcomingSongs: [Song] = []
    @Published var currentPlaybackSongs: [Song] = []
    @Published var shuffleQueue: [Song] = []
    @Published var isSeeking = false

    @Published var isShuffleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isShuffleEnabled, forKey: "isShuffleEnabled")
            if isShuffleEnabled {
                if let song = selectedSong {
                    rebuildShuffleQueue(startingFrom: song)
                }
            } else {
                shuffleQueue.removeAll()
                playedShuffleSongs.removeAll()
            }
            updateUpcomingSongs()
        }
    }

    @Published var isRepeatEnabled: Bool {
        didSet { UserDefaults.standard.set(isRepeatEnabled, forKey: "isRepeatEnabled") }
    }

    @Published var isRepeatOne: Bool {
        didSet {
            UserDefaults.standard.set(isRepeatOne, forKey: "isRepeatOne")
            updateUpcomingSongs()
        }
    }

    @Published var volume: Double {
        didSet {
            UserDefaults.standard.set(volume, forKey: "playerVolume")
            // During a crossfade the fade timer owns the player volumes.
            if fadeTimer == nil { player?.volume = effectiveVolume }
            updateNowPlayingInfo()
        }
    }

    // MARK: - Internal bookkeeping (no UI binding needed)

    var playerItem: AVPlayerItem?
    var timeObserverToken: Any?
    var playbackEndObserver: NSObjectProtocol?
    var manualQueue: [Song] = []
    var playedShuffleSongs: [Song] = []
    var isNavigatingBackward = false

    // Crossfade bookkeeping: while fading, the previous song's player keeps playing
    // in `fadingOutPlayer` as the new song's player fades in.
    private var crossfadeObserverToken: Any?
    private var crossfadeAttemptedItem: AVPlayerItem?
    private var isCrossfadeArmed = false
    private var fadingOutPlayer: AVPlayer?
    private var fadeTimer: Timer?
    private var fadeStartDate: Date?
    private var fadeLength: Double = 0

    // Stable Volume: per-song gain (<= 1) that evens out loudness between songs.
    private var songGain: Float = 1
    private var fadingOutGain: Float = 1
    private var lastStableVolumeState = false

    private var isStableVolumeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "isStableVolumeEnabled")
    }

    /// Gain applied to the current song on top of the user's volume.
    private var gainFactor: Float { isStableVolumeEnabled ? songGain : 1 }
    private var effectiveVolume: Float { Float(volume) * gainFactor }

    /// Set (and refreshed) by ContentView every time it appears. Lets the
    /// engine ask "what's the current library/playlist/album context" using
    /// whatever is currently visible.
    var contextProvider: (Song?) -> [Song] = { _ in [] }

    /// Set (and refreshed) by ContentView every time it appears. Runs
    /// UI-facing side effects (play counts, system playlists, lyrics)
    /// whenever a new song starts.
    var onSongChanged: ((Song) -> Void)?

    private init() {
        isShuffleEnabled = UserDefaults.standard.bool(forKey: "isShuffleEnabled")
        isRepeatEnabled = UserDefaults.standard.bool(forKey: "isRepeatEnabled")
        isRepeatOne = UserDefaults.standard.bool(forKey: "isRepeatOne")
        volume = (UserDefaults.standard.object(forKey: "playerVolume") as? Double) ?? 0.5
        setupRemoteCommands()
        observeDefaultOutputDevice()
        lastStableVolumeState = isStableVolumeEnabled
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isStableVolumeEnabled != self.lastStableVolumeState else { return }
            self.lastStableVolumeState = self.isStableVolumeEnabled
            self.refreshStableVolume()
        }
    }

    // MARK: - Stable Volume

    /// Measures the current song (cached after the first time) and applies its gain.
    private func refreshStableVolume() {
        if fadeTimer == nil { player?.volume = effectiveVolume }
        guard isStableVolumeEnabled, let song = selectedSong else { return }
        Task { @MainActor [weak self] in
            let gain = await StableVolumeIndex.shared.gain(for: song.url)
            guard let self, self.selectedSong?.id == song.id else { return }
            self.songGain = gain
            if self.fadeTimer == nil { self.player?.volume = self.effectiveVolume }
        }
    }

    // MARK: - Settings-driven behavior

    private static let lastSongPathKey = "lastPlayedSongPath"
    private static let lastPositionKey = "lastPlayedPositionSeconds"

    /// Pauses playback when the system's default output device changes (headphones
    /// unplugged, Bluetooth disconnected, etc.), if enabled in Settings.
    private func observeDefaultOutputDevice() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            guard let self,
                  UserDefaults.standard.bool(forKey: "pauseOnOutputDeviceChange"),
                  let player = self.player, player.rate != 0 else { return }
            player.pause()
            self.updateNowPlayingInfo()
        }
    }

    /// Loads the song that was playing when the app last quit, paused at its saved position,
    /// if "Resume last song on launch" is enabled and nothing is playing yet.
    func restoreLastSong(from library: [Song]) {
        guard UserDefaults.standard.bool(forKey: "resumeLastSongOnLaunch"),
              selectedSong == nil,
              let path = UserDefaults.standard.string(forKey: Self.lastSongPathKey),
              let song = library.first(where: { $0.url.path == path }) else { return }
        let seconds = UserDefaults.standard.double(forKey: Self.lastPositionKey)
        currentPlaybackSongs = contextProvider(song)
        setupNewPlayback(for: song, autoplay: false, startAt: seconds)
        updateUpcomingSongs()
    }

    // MARK: - Playback

    func playSong(_ song: Song) {
        currentPlaybackSongs = contextProvider(song)

        if isShuffleEnabled {
            if !isNavigatingBackward {
                if playedShuffleSongs.isEmpty || playedShuffleSongs.last?.id != song.id {
                    rebuildShuffleQueue(startingFrom: song)
                }
            }
        } else {
            playedShuffleSongs.removeAll()
        }

        isNavigatingBackward = false

        setupNewPlayback(for: song)
        updateUpcomingSongs()
    }

    func playSongFromUpNext(_ song: Song) {
        manualQueue.removeAll { $0.id == song.id }
        shuffleQueue.removeAll { $0.id == song.id }
        playedShuffleSongs.append(song)
        setupNewPlayback(for: song)
        updateUpcomingSongs()
    }

    private func setupNewPlayback(for song: Song, autoplay: Bool = true, startAt seconds: Double = 0) {
        stopCurrentPlayback()

        let item = AVPlayerItem(url: song.url)
        Equalizer.shared.attach(to: item)
        let newPlayer = AVPlayer(playerItem: item)
        let isCrossfading = fadingOutPlayer != nil
        songGain = 1
        newPlayer.volume = isCrossfading ? 0 : Float(volume)
        if seconds > 0 {
            newPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        if autoplay {
            newPlayer.play()
        }
        UserDefaults.standard.set(song.url.path, forKey: Self.lastSongPathKey)
        UserDefaults.standard.set(seconds, forKey: Self.lastPositionKey)

        player = newPlayer
        playerItem = item
        selectedSong = song

        if let d = song.duration {
            playbackDuration = d
        } else {
            Task {
                let seconds = (try? await item.asset.load(.duration).seconds) ?? 0
                await MainActor.run { self.playbackDuration = seconds }
            }
        }

        playbackPosition = (seconds > 0 && playbackDuration > 0) ? min(seconds / playbackDuration, 1) : 0.0

        refreshStableVolume()

        setupTimeObserver(for: newPlayer)
        setupCrossfadeObserver(for: newPlayer)
        setupPlaybackCompletionHandler(for: item)
        if isCrossfading { beginFadeTimer() }
        updateNowPlayingInfo()

        // A restored (paused) song isn't a new play, so skip play counts/history.
        if autoplay {
            onSongChanged?(song)
        }
    }

    private func stopCurrentPlayback() {
        // An automatic crossfade lets the outgoing song keep playing instead of pausing it.
        let shouldCrossfade = isCrossfadeArmed && player?.rate != 0
        finishCrossfade()

        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let token = crossfadeObserverToken {
            player?.removeTimeObserver(token)
            crossfadeObserverToken = nil
        }
        if let token = playbackEndObserver {
            NotificationCenter.default.removeObserver(token)
            playbackEndObserver = nil
        }
        if shouldCrossfade {
            fadingOutPlayer = player
            fadingOutGain = gainFactor
        } else {
            player?.pause()
        }
        playerItem = nil
        player = nil
    }

    // MARK: - Crossfade

    /// Watches playback and starts the next song early so it overlaps the end of this one.
    private func setupCrossfadeObserver(for player: AVPlayer) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        crossfadeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.checkCrossfade(at: time.seconds)
        }
    }

    private func checkCrossfade(at position: Double) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "isCrossfadeEnabled"),
              !isRepeatOne, !isSeeking, fadeTimer == nil,
              let player, player.rate != 0,
              let item = playerItem, item !== crossfadeAttemptedItem else { return }

        let configured = (defaults.object(forKey: "crossfadeDuration") as? Double) ?? 6.0
        let fade = min(max(configured, 1), 12)
        let remaining = playbackDuration - position
        // Skip songs too short to fade (and a duration that hasn't loaded yet).
        guard playbackDuration > fade * 2, remaining <= fade, remaining > 0.3 else { return }

        // Only try once per song; playNext() does nothing at the end of the list.
        crossfadeAttemptedItem = item
        fadeLength = remaining
        isCrossfadeArmed = true
        playNext()
        isCrossfadeArmed = false
    }

    private func beginFadeTimer() {
        fadeStartDate = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.stepFade()
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    /// Equal-power curve so the combined loudness stays steady through the fade.
    private func stepFade() {
        guard let start = fadeStartDate else { return }
        let progress = min(Date().timeIntervalSince(start) / max(fadeLength, 0.1), 1)
        let base = Float(volume)
        fadingOutPlayer?.volume = base * fadingOutGain * Float(cos(progress * .pi / 2))
        player?.volume = base * gainFactor * Float(sin(progress * .pi / 2))
        if progress >= 1 { finishCrossfade() }
    }

    private func finishCrossfade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadeStartDate = nil
        fadingOutPlayer?.pause()
        fadingOutPlayer = nil
        player?.volume = effectiveVolume
    }

    private func setupTimeObserver(for player: AVPlayer) {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        let interval = CMTime(seconds: 1.0, preferredTimescale: 1)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            if !self.isSeeking {
                UserDefaults.standard.set(time.seconds, forKey: Self.lastPositionKey)
                self.playbackPosition = time.seconds / max(self.playbackDuration, 0.1)
                self.updateNowPlayingPlaybackInfo()
            }
        }
    }

    private func setupPlaybackCompletionHandler(for item: AVPlayerItem) {
        if let token = playbackEndObserver {
            NotificationCenter.default.removeObserver(token)
            playbackEndObserver = nil
        }
        playbackEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.isRepeatOne {
                self.player?.seek(to: .zero)
                self.player?.play()
                self.playbackPosition = 0.0
                self.updateNowPlayingInfo()
            } else {
                self.playNext()
            }
        }
    }

    func playNext() {
        guard let current = selectedSong else { return }

        if !isShuffleEnabled && !manualQueue.isEmpty {
            let next = manualQueue.removeFirst()
            playSong(next)
            return
        }

        if isShuffleEnabled {
            if shuffleQueue.isEmpty {
                if isRepeatEnabled || isRepeatOne {
                    let context = contextProvider(current)
                    let pool = context.filter { song in
                        if song.id == current.id { return false }
                        return !playedShuffleSongs.contains { $0.id == song.id }
                    }
                    if !pool.isEmpty {
                        shuffleQueue = pool.shuffled()
                    } else {
                        rebuildShuffleQueue(startingFrom: current)
                    }
                } else {
                    return
                }
            }

            if let next = shuffleQueue.first {
                shuffleQueue.removeFirst()
                playedShuffleSongs.append(next)
                playSong(next)
                return
            }
        }

        playNextSequentialSong(after: current)
    }

    func playPrevious() {
        guard let current = selectedSong else { return }

        isNavigatingBackward = true

        if isShuffleEnabled {
            if playedShuffleSongs.count > 1 {
                let justLeftSong = playedShuffleSongs.removeLast()
                if let previousSong = playedShuffleSongs.last {
                    shuffleQueue.insert(justLeftSong, at: 0)
                    playSong(previousSong)
                    return
                }
            } else if playedShuffleSongs.count == 1 {
                player?.seek(to: .zero)
                playbackPosition = 0.0
                updateNowPlayingPlaybackInfo()
                return
            }
            playRandomSong(excluding: current)
            return
        }

        playPreviousSequentialSong(before: current)
    }

    private func playRandomSong(excluding current: Song) {
        let pool = currentPlaybackSongs.filter { $0.id != current.id }
        if let randomSong = pool.randomElement() {
            playSong(randomSong)
        }
    }

    private func playNextSequentialSong(after current: Song) {
        currentPlaybackSongs = contextProvider(current)
        guard let currentIndex = currentPlaybackSongs.firstIndex(where: { $0.id == current.id }) else { return }

        let nextIndex = currentIndex + 1
        if nextIndex < currentPlaybackSongs.count {
            playSong(currentPlaybackSongs[nextIndex])
        } else if isRepeatEnabled || isRepeatOne {
            playSong(currentPlaybackSongs.first!)
        }
    }

    private func playPreviousSequentialSong(before current: Song) {
        currentPlaybackSongs = contextProvider(current)
        guard let currentIndex = currentPlaybackSongs.firstIndex(where: { $0.id == current.id }) else { return }

        let previousIndex = currentIndex - 1
        if previousIndex >= 0 {
            playSong(currentPlaybackSongs[previousIndex])
        } else if isRepeatEnabled || isRepeatOne {
            playSong(currentPlaybackSongs.last!)
        }
    }

    private func rebuildShuffleQueue(startingFrom current: Song) {
        let context = contextProvider(current)
        let pool = context.filter { $0.id != current.id }
        shuffleQueue = pool.shuffled()
        playedShuffleSongs.removeAll()
        playedShuffleSongs.append(current)
    }

    func addSongsNext(_ newSongs: [Song]) {
        guard !isRepeatOne else { return }

        DispatchQueue.main.async {
            let currentID = self.selectedSong?.id
            var seen = Set<UUID>()
            let filtered = newSongs.filter { s in
                guard s.id != currentID else { return false }
                if seen.contains(s.id) { return false }
                seen.insert(s.id)
                return true
            }
            guard !filtered.isEmpty else { return }

            if self.isShuffleEnabled {
                let ids = Set(filtered.map { $0.id })
                self.shuffleQueue.removeAll { ids.contains($0.id) }
                self.shuffleQueue.insert(contentsOf: filtered, at: 0)
            } else {
                let ids = Set(filtered.map { $0.id })
                self.manualQueue.removeAll { ids.contains($0.id) }
                self.manualQueue.insert(contentsOf: filtered, at: 0)
            }
            self.updateUpcomingSongs()
        }
    }

    func moveUpcomingSongs(from source: IndexSet, to destination: Int) {
        if isShuffleEnabled {
            let tail = shuffleQueue.count > upcomingSongs.count
                ? Array(shuffleQueue[upcomingSongs.count...])
                : []
            shuffleQueue = upcomingSongs + tail
        } else {
            manualQueue = upcomingSongs
        }
    }

    func updateUpcomingSongs() {
        guard let current = selectedSong else {
            upcomingSongs = []
            return
        }

        if isRepeatOne {
            upcomingSongs = []
            return
        }

        if isShuffleEnabled {
            upcomingSongs = Array(shuffleQueue.prefix(25))
            return
        }

        var computed: [Song] = []
        if let currentIndex = currentPlaybackSongs.firstIndex(where: { $0.id == current.id }) {
            let startIndex = currentIndex + 1
            let endIndex = min(startIndex + 25, currentPlaybackSongs.count)
            if startIndex < endIndex {
                computed = Array(currentPlaybackSongs[startIndex..<endIndex])
            }
            if isRepeatEnabled && computed.count < 25 {
                let needed = 25 - computed.count
                computed.append(contentsOf: currentPlaybackSongs.prefix(needed))
            }
        }

        let manualIDs = Set(manualQueue.map { $0.id })
        let filteredComputed = computed.filter { !manualIDs.contains($0.id) }
        upcomingSongs = manualQueue + filteredComputed
    }

    func handleSeek(_ value: Double) {
        if value == -1 {
            player?.volume = effectiveVolume
        } else {
            let seconds = value * playbackDuration
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            player?.seek(to: time)
            updateNowPlayingPlaybackInfo()
        }
    }

    func togglePlayPause() {
        if player?.rate != 0 {
            player?.pause()
            fadingOutPlayer?.pause()
        } else {
            player?.play()
            fadingOutPlayer?.play()
        }
        updateNowPlayingInfo()
    }

    func play() {
        player?.play()
        fadingOutPlayer?.play()
        updateNowPlayingInfo()
    }

    func pause() {
        player?.pause()
        fadingOutPlayer?.pause()
    }

    // MARK: - Remote commands / Now Playing

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .commandFailed }
            if player.rate == 0 {
                player.play()
                self.updateNowPlayingInfo()
                return .success
            }
            return .commandFailed
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .commandFailed }
            if player.rate != 0 {
                player.pause()
                self.updateNowPlayingInfo()
                return .success
            }
            return .commandFailed
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .commandFailed }
            if player.rate == 0 {
                player.play()
            } else {
                player.pause()
            }
            self.updateNowPlayingInfo()
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.playNext()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.playPrevious()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let player = self.player else { return .commandFailed }
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }

            let time = CMTime(seconds: event.positionTime, preferredTimescale: 600)
            player.seek(to: time)
            self.updateNowPlayingPlaybackInfo()
            return .success
        }
    }

    func updateNowPlayingInfo() {
        guard let song = selectedSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = song.album
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = playbackDuration

        if let artworkData = song.artworkData,
           let artworkImage = NSImage(data: artworkData) {
            let artwork = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        if let player = player {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player?.rate ?? 0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func updateNowPlayingPlaybackInfo() {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }

        if let player = player {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player?.rate ?? 0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}
