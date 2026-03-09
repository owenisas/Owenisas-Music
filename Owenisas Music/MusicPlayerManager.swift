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
    private var timer: AnyCancellable?

    // MARK: – Published State
    @Published var isPlaying = false
    @Published var currentSong: Song?
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isShuffled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var showFullPlayer = false

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

    /// Resume current song (no queue change)
    func resume() {
        player?.play()
        isPlaying = true
        startTimer()
        updateNowPlayingInfo()
    }

    private func loadAndPlay(_ song: Song) {
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
        } catch {
            print("Error playing \(song.title): \(error)")
        }
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
        guard !queue.isEmpty else { return }
        let nextIndex = currentIndex + 1
        if nextIndex < queue.count {
            currentIndex = nextIndex
            loadAndPlay(queue[nextIndex])
        } else if repeatMode == .all {
            currentIndex = 0
            loadAndPlay(queue[0])
        }
    }

    func previous() {
        // If more than 3s in, restart; otherwise go to previous
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard !queue.isEmpty else { return }
        let prevIndex = currentIndex - 1
        if prevIndex >= 0 {
            currentIndex = prevIndex
            loadAndPlay(queue[prevIndex])
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
            loadAndPlay(queue[currentIndex])
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
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let p = self.player else { return }
                self.currentTime = p.currentTime
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
        if let image = UIImage(contentsOfFile: song.coverImageURL.path) {
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

// MARK: - AVAudioPlayerDelegate
extension MusicPlayerManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
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
                    self.loadAndPlay(self.queue[nextIndex])
                } else {
                    self.isPlaying = false
                    self.currentSong = nil
                    self.updateNowPlayingInfo(clear: true)
                }
            }
        }
    }
}
