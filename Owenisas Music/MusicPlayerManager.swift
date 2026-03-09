import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum RepeatMode: Int, CaseIterable {
    case off = 0
    case all = 1
    case one = 2

    var icon: String {
        switch self {
        case .off:  return "repeat"
        case .all:  return "repeat"
        case .one:  return "repeat.1"
        }
    }

    var isActive: Bool { self != .off }
}

class MusicPlayerManager: NSObject, ObservableObject {
    static let shared = MusicPlayerManager()

    private var player: AVAudioPlayer?
    private var secondaryPlayer: AVAudioPlayer?
    private var timer: AnyCancellable?

    // MARK: – Published State
    @Published var isPlaying = false
    @Published var currentSong: Song?
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isShuffled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var showFullPlayer = false
    @Published var crossfadeEnabled = true
    @Published var crossfadeDuration: TimeInterval = 3.0

    // MARK: – Queue
    /// The original ordered queue (before shuffle)
    private var originalQueue: [Song] = []
    /// The active queue (may be shuffled)
    @Published var queue: [Song] = []
    @Published var currentIndex: Int = 0

    /// Public read-only playlist access
    var playlist: [Song] { queue }

    // MARK: - Init
    override init() {
        super.init()
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: []
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Error setting up audio session: \(error)")
        }
        setupRemoteCommandCenter()
        setupInterruptionObserver()
    }

    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        if type == .began {
            pause()
        } else if type == .ended {
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    resume()
                }
            }
        }
    }

    // MARK: - Play
    func play(song: Song, in playlist: [Song]? = nil) {
        if let list = playlist {
            originalQueue = list
            if isShuffled {
                var shuffled = list.filter { $0.id != song.id }
                shuffled.shuffle()
                queue = [song] + shuffled
            } else {
                queue = list
            }
        }

        // Find index in active queue
        if let idx = queue.firstIndex(where: { $0.id == song.id }) {
            currentIndex = idx
        }

        loadAndPlay(song)
    }
    
    // MARK: - Queue Management
    func playNext(_ song: Song) {
        if queue.isEmpty {
            play(song: song, in: [song])
            return
        }
        
        let nextIndex = currentIndex + 1
        if nextIndex <= queue.count {
            queue.insert(song, at: nextIndex)
            // Also update original queue if it contains the song
            if !originalQueue.contains(where: { $0.id == song.id }) {
                originalQueue.append(song)
            }
        }
    }
    
    func addToQueue(_ song: Song) {
        if queue.isEmpty {
            play(song: song, in: [song])
            return
        }
        
        queue.append(song)
        if !originalQueue.contains(where: { $0.id == song.id }) {
            originalQueue.append(song)
        }
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        // Re-calculate currentIndex
        if let current = currentSong, let idx = queue.firstIndex(where: { $0.id == current.id }) {
            currentIndex = idx
        }
    }

    func removeFromQueue(at offsets: IndexSet) {
        let currentId = currentSong?.id
        queue.remove(atOffsets: offsets)
        
        // If current song was removed, stop or play next
        if let currentId = currentId, !queue.contains(where: { $0.id == currentId }) {
            if queue.isEmpty {
                stop()
            } else {
                next()
            }
        } else if let current = currentSong, let idx = queue.firstIndex(where: { $0.id == current.id }) {
            currentIndex = idx
        }
    }

    func stopAndRemoveFromQueue(songId: String) {
        if currentSong?.id == songId {
            stop()
        }
        queue.removeAll { $0.id == songId }
        originalQueue.removeAll { $0.id == songId }
        
        if let current = currentSong, let idx = queue.firstIndex(where: { $0.id == current.id }) {
            currentIndex = idx
        }
    }

    // MARK: - Playback
    func resume() {
        player?.play()
        isPlaying = true
        startTimer()
        updateNowPlayingInfo()
    }

    private func loadAndPlay(_ song: Song, crossfade: Bool = false) {
        if crossfade && crossfadeEnabled {
            performCrossfade(to: song)
            return
        }

        stopTimer()
        player?.stop()
        currentSong = song

        do {
            player = try AVAudioPlayer(contentsOf: song.audioFileURL)
            player?.delegate = self
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            currentTime = 0
            player?.play()
            isPlaying = true
            startTimer()
            updateNowPlayingInfo()
            updateListeningHistory(song)
        } catch {
            print("Error playing \(song.title): \(error)")
            isPlaying = false
            currentSong = nil
            stopTimer()
            updateNowPlayingInfo(clear: true)
        }
    }

    private func performCrossfade(to song: Song) {
        guard let oldPlayer = player else {
            loadAndPlay(song, crossfade: false)
            return
        }

        do {
            secondaryPlayer = try AVAudioPlayer(contentsOf: song.audioFileURL)
            secondaryPlayer?.delegate = self
            secondaryPlayer?.volume = 0
            secondaryPlayer?.prepareToPlay()
            secondaryPlayer?.play()

            // Crossfade
            oldPlayer.setVolume(0, fadeDuration: crossfadeDuration)
            secondaryPlayer?.setVolume(1.0, fadeDuration: crossfadeDuration)

            currentSong = song
            duration = secondaryPlayer?.duration ?? 0
            currentTime = 0
            isPlaying = true
            updateNowPlayingInfo()
            updateListeningHistory(song)

            // After fade completes, clean up
            DispatchQueue.main.asyncAfter(deadline: .now() + crossfadeDuration) { [weak self] in
                oldPlayer.stop()
                self?.player = self?.secondaryPlayer
                self?.secondaryPlayer = nil
            }
        } catch {
            print("Crossfade fail: \(error)")
            loadAndPlay(song, crossfade: false)
        }
    }

    private func updateListeningHistory(_ song: Song) {
        // Find SongData in SwiftData and update lastPlayedDate
        // We'll let DataManager handle this via a notification or direct call if we had the context
        // For now, let's assume DataManager listens or we call it
        NotificationCenter.default.post(name: .init("SongPlayed"), object: song.id)
    }

    func toggleFavorite() {
        guard var song = currentSong else { return }
        song.isFavorited.toggle()
        currentSong = song
        NotificationCenter.default.post(name: .init("SongFavoriteToggled"), object: song.id)
    }

    // MARK: - Pause / Stop
    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else if currentSong != nil {
            resume()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        secondaryPlayer?.stop()
        secondaryPlayer = nil
        isPlaying = false
        currentSong = nil
        currentTime = 0
        duration = 0
        stopTimer()
        updateNowPlayingInfo(clear: true)
    }

    // MARK: - Seek
    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
        updateNowPlayingInfo()
    }

    // MARK: - Next / Previous
    func next() {
        guard !queue.isEmpty else {
            stop()
            return
        }
        let nextIndex = currentIndex + 1
        if nextIndex < queue.count {
            currentIndex = nextIndex
            loadAndPlay(queue[nextIndex], crossfade: true)
        } else if repeatMode == .all {
            currentIndex = 0
            loadAndPlay(queue[0], crossfade: true)
        } else {
            stop()
        }
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard !queue.isEmpty else { return }
        let prevIndex = currentIndex - 1
        if prevIndex >= 0 {
            currentIndex = prevIndex
            loadAndPlay(queue[prevIndex], crossfade: true)
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
            loadAndPlay(queue[currentIndex], crossfade: true)
        } else {
            seek(to: 0)
        }
    }

    // MARK: - Shuffle
    func toggleShuffle() {
        isShuffled.toggle()
        guard let current = currentSong else { return }
        if isShuffled {
            var rest = queue.filter { $0.id != current.id }
            rest.shuffle()
            queue = [current] + rest
            currentIndex = 0
        } else {
            queue = originalQueue
            if let idx = queue.firstIndex(where: { $0.id == current.id }) {
                currentIndex = idx
            }
        }
    }

    // MARK: - Repeat
    func cycleRepeatMode() {
        let next = (repeatMode.rawValue + 1) % RepeatMode.allCases.count
        repeatMode = RepeatMode(rawValue: next) ?? .off
    }

    // MARK: - Timer (progress tracking)
    private func startTimer() {
        timer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let p = self.player else { return }
                self.currentTime = p.currentTime
                
                // Auto-next logic: If near end and crossfade enabled
                if self.crossfadeEnabled && (p.duration - p.currentTime) < self.crossfadeDuration && !p.isLooping {
                    // Start preparing next? Actually AVAudioPlayerDidFinishPlaying is safer for basic flow.
                }
            }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Format helpers
    static func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite else { return "0:00" }
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }

    // MARK: - Now Playing Info
    private func updateNowPlayingInfo(clear: Bool = false) {
        if clear {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        guard let song = currentSong, let player = player else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.albumTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let path = song.coverImageURL?.path, let image = UIImage(contentsOfFile: path) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote Command Center
    private func setupRemoteCommandCenter() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let e = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            self.seek(to: e.positionTime)
            return .success
        }
    }
}

// Extension to help with loops if needed
extension AVAudioPlayer {
    var isLooping: Bool { numberOfLoops != 0 }
}

// MARK: - AVAudioPlayerDelegate
extension MusicPlayerManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // If this was the secondary player from a crossfade, ignore
        if player == secondaryPlayer { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch self.repeatMode {
            case .one:
                if let song = self.currentSong {
                    self.loadAndPlay(song)
                }
            case .all:
                self.next()
            case .off:
                let nextIndex = self.currentIndex + 1
                if nextIndex < self.queue.count {
                    self.currentIndex = nextIndex
                    self.loadAndPlay(self.queue[nextIndex], crossfade: true)
                } else {
                    self.isPlaying = false
                    self.currentSong = nil
                    self.updateNowPlayingInfo(clear: true)
                }
            }
        }
    }
}

