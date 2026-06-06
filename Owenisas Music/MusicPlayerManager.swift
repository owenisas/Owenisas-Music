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
    var currentTime: TimeInterval = 0 // No longer @Published to save global CPU/battery
    @Published var duration: TimeInterval = 0
    @Published var isShuffled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var showFullPlayer = false
    @Published var showMiniPlayer = true
    @Published var crossfadeEnabled = true
    @Published var crossfadeDuration: TimeInterval = 3.0

    /// Playback speed (0.5x – 2.0x). Persisted across launches.
    @Published var playbackRate: Float = UserDefaults.standard.object(forKey: "playbackRate") as? Float ?? 1.0 {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: "playbackRate")
            applyPlaybackRate()
        }
    }

    /// Available speed presets surfaced in the UI.
    static let playbackRatePresets: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    // MARK: – Sleep Timer
    @Published var sleepTimerActive = false
    @Published var sleepTimerEndDate: Date?
    @Published var sleepTimerEndOfTrack = false
    private var sleepTimer: AnyCancellable?

    // MARK: – Queue
    /// The original ordered queue (before shuffle)
    private var originalQueue: [Song] = []
    /// The active queue (may be shuffled)
    @Published var queue: [Song] = []
    @Published var currentIndex: Int = 0
    private var backgroundTicks: Int = 0

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
        originalQueue = queue

        // Re-calculate currentIndex
        if let current = currentSong, let idx = queue.firstIndex(where: { $0.id == current.id }) {
            currentIndex = idx
        }
    }

    func removeFromQueue(at offsets: IndexSet) {
        let currentId = currentSong?.id
        let removedSongs = offsets.compactMap { index in
            index < queue.count ? queue[index] : nil
        }
        queue.remove(atOffsets: offsets)
        let removedIDs = Set(removedSongs.map { $0.id })
        originalQueue.removeAll { removedIDs.contains($0.id) }
        
        if let currentId = currentId, let idx = queue.firstIndex(where: { $0.id == currentId }) {
            // Current song is still in the queue, just update its index!
            currentIndex = idx
        } else {
            // Current song was removed.
            if queue.isEmpty {
                stop()
            } else {
                // If currentIndex >= queue.count, we removed the last item.
                if currentIndex >= queue.count {
                    if repeatMode == .all {
                        currentIndex = 0
                        loadAndPlay(queue[0], crossfade: true)
                    } else {
                        stop()
                    }
                } else {
                    // Start playing the item that shifted into currentIndex
                    loadAndPlay(queue[currentIndex], crossfade: true)
                }
            }
        }
    }

    func stopAndRemoveFromQueue(songId: String) {
        let removedCurrentSong = currentSong?.id == songId
        // Capture the position before stop() resets currentIndex to 0, so that
        // removing the current track advances to the song that shifts into its
        // slot rather than restarting from the top of the queue.
        let savedIndex = currentIndex
        if removedCurrentSong {
            stop()
        }
        queue.removeAll { $0.id == songId }
        originalQueue.removeAll { $0.id == songId }

        guard !queue.isEmpty else {
            currentIndex = 0
            return
        }

        if removedCurrentSong {
            currentIndex = min(savedIndex, queue.count - 1)
            loadAndPlay(queue[currentIndex], crossfade: false)
            return
        }
        
        if let current = currentSong, let idx = queue.firstIndex(where: { $0.id == current.id }) {
            currentIndex = idx
        }
    }

    // MARK: - Playback
    func resume() {
        player?.play()
        player?.rate = playbackRate
        isPlaying = true
        startTimer()
        updateNowPlayingInfo()
    }

    // MARK: - Playback Speed
    /// Apply the current speed to whichever player is active without interrupting playback.
    private func applyPlaybackRate() {
        let activePlayer = secondaryPlayer ?? player
        activePlayer?.enableRate = true
        if isPlaying {
            activePlayer?.rate = playbackRate
        }
        updateNowPlayingInfo()
    }

    /// Step to the next speed preset, wrapping back to the start.
    func cyclePlaybackRate() {
        let presets = Self.playbackRatePresets
        let currentIdx = presets.firstIndex(of: playbackRate) ?? presets.firstIndex(of: 1.0) ?? 0
        playbackRate = presets[(currentIdx + 1) % presets.count]
    }

    private func loadAndPlay(_ song: Song, crossfade: Bool = false) {
        if crossfade && crossfadeEnabled {
            performCrossfade(to: song)
            return
        }

        stopTimer()
        player?.stop()
        print("[DEBUG] MusicPlayer: Loading and playing song: \(song.title) (ID: \(song.id))")
        currentSong = song

        do {
            // Check if file exists and is valid
            let fm = FileManager.default
            if !fm.fileExists(atPath: song.audioFileURL.path) {
                throw NSError(domain: "MusicPlayer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Audio file missing on disk"])
            }
            let attr = try fm.attributesOfItem(atPath: song.audioFileURL.path)
            if (attr[.size] as? Int64 ?? 0) < 500_000 {
                throw NSError(domain: "MusicPlayer", code: 500, userInfo: [NSLocalizedDescriptionKey: "Audio file is corrupted or too small"])
            }

            player = try Self.makeAudioPlayer(for: song.audioFileURL)
            player?.delegate = self
            player?.enableRate = true
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            currentTime = 0
            player?.play()
            player?.rate = playbackRate
            isPlaying = true
            startTimer()
            updateNowPlayingInfo()
            updateListeningHistory(song)
        } catch {
            print("Error playing \(song.title): \(error)")
            NSLog("OWENISAS_PLAYER: load failed for %@ at %@: %@", song.title, song.audioFileURL.path, "\(error)")
            // If play fails, try to skip to next automatically
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.next()
            }
        }
    }

    /// Build an AVAudioPlayer that handles our downloads even when the saved
    /// extension doesn't match the actual container (e.g. m4a content saved as .mp3).
    /// We sniff the first bytes for an mp4 (`ftyp`) header and pass the right hint.
    private static func makeAudioPlayer(for url: URL) throws -> AVAudioPlayer {
        let fileTypeHint: String? = {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 12)) ?? Data()
            if head.count >= 8 {
                let ftyp = head.subdata(in: 4..<8)
                if let s = String(data: ftyp, encoding: .ascii), s == "ftyp" {
                    return AVFileType.m4a.rawValue
                }
            }
            if head.count >= 4 {
                let bytes = Array(head)
                if bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53 {
                    return "org.xiph.ogg-audio"
                }
            }
            return nil
        }()
        if let hint = fileTypeHint {
            return try AVAudioPlayer(contentsOf: url, fileTypeHint: hint)
        }
        return try AVAudioPlayer(contentsOf: url)
    }

    private func performCrossfade(to song: Song) {
        guard let oldPlayer = player else {
            loadAndPlay(song, crossfade: false)
            return
        }

        do {
            secondaryPlayer = try Self.makeAudioPlayer(for: song.audioFileURL)
            secondaryPlayer?.delegate = self
            secondaryPlayer?.enableRate = true
            secondaryPlayer?.volume = 0
            secondaryPlayer?.prepareToPlay()
            print("[DEBUG] MusicPlayer: Starting crossfade to: \(song.title)")
            secondaryPlayer?.play()
            secondaryPlayer?.rate = playbackRate

            // Crossfade
            oldPlayer.setVolume(0, fadeDuration: crossfadeDuration)
            secondaryPlayer?.setVolume(1.0, fadeDuration: crossfadeDuration)

            currentSong = song
            duration = secondaryPlayer?.duration ?? 0
            currentTime = 0
            isPlaying = true
            updateListeningHistory(song)

            // After fade completes, clean up and update NowPlaying with correct elapsed time
            DispatchQueue.main.asyncAfter(deadline: .now() + crossfadeDuration) { [weak self] in
                guard let self = self else { return }
                oldPlayer.stop()
                self.player = self.secondaryPlayer
                self.secondaryPlayer = nil
                // Now that self.player points to the new player, sync the accurate elapsed time
                self.currentTime = self.player?.currentTime ?? 0
                self.updateNowPlayingInfo()
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
        if let current = currentSong {
            toggleFavorite(for: current.id)
        }
    }

    func toggleFavorite(for songId: String) {
        // Broadcast to DataManager to persist the change in SwiftData
        NotificationCenter.default.post(name: .init("SongFavoriteToggled"), object: songId)
        
        // Ensure the currently playing song is perfectly synced on the Now Playing screen
        if var current = currentSong, current.id == songId {
            current.isFavorited.toggle()
            currentSong = current
        }
        
        // Sync the internal player queues correctly so when `next` plays, it still displays the Like correctly
        if let idx = queue.firstIndex(where: { $0.id == songId }) {
            queue[idx].isFavorited.toggle()
        }
        if let idx = originalQueue.firstIndex(where: { $0.id == songId }) {
            originalQueue[idx].isFavorited.toggle()
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
        secondaryPlayer?.stop()
        secondaryPlayer = nil
        isPlaying = false
        currentSong = nil
        currentIndex = 0
        currentTime = 0
        duration = 0
        stopTimer()
        updateNowPlayingInfo(clear: true)
    }

    // MARK: - Seek
    func seek(to time: TimeInterval) {
        let activePlayer = secondaryPlayer ?? player
        activePlayer?.currentTime = time
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
        if let current = currentSong {
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
        } else {
            // If nothing is playing, just shuffle the whole queue
            if isShuffled {
                queue.shuffle()
                currentIndex = 0
            } else {
                queue = originalQueue
                currentIndex = 0
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
        stopTimer()
        timer = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let p = self.player else { return }
                
                self.currentTime = p.currentTime
                
                // Periodically sync Control Center elapsed time
                self.backgroundTicks += 1
                if self.backgroundTicks % 4 == 0 { // ~every 1 second
                    self.updateNowPlayingElapsedTime()
                }
                
                // Auto-next logic: If near end and crossfade enabled
                if self.crossfadeEnabled && (p.duration - p.currentTime) <= self.crossfadeDuration && !p.isLooping {
                    if self.secondaryPlayer == nil {
                        var shouldCrossfade = false
                        if self.repeatMode == .one || self.repeatMode == .all {
                            shouldCrossfade = true
                        } else if self.currentIndex + 1 < self.queue.count {
                            shouldCrossfade = true
                        }
                        
                        if shouldCrossfade {
                            self.autoAdvance()
                        }
                    }
                }
            }
    }

    private func autoAdvance() {
        print("[DEBUG] MusicPlayer: Auto-advancing to next song (Repeat Mode: \(repeatMode))")
        switch repeatMode {
        case .one:
            if let song = currentSong {
                loadAndPlay(song, crossfade: true)
            }
        case .all:
            let nextIndex = currentIndex + 1
            if nextIndex < queue.count {
                currentIndex = nextIndex
                loadAndPlay(queue[nextIndex], crossfade: true)
            } else {
                currentIndex = 0
                loadAndPlay(queue[0], crossfade: true)
            }
        case .off:
            let nextIndex = currentIndex + 1
            if nextIndex < queue.count {
                currentIndex = nextIndex
                loadAndPlay(queue[nextIndex], crossfade: true)
            }
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    /// Lightweight update: only syncs elapsed time without rebuilding the full NowPlaying dict
    private func updateNowPlayingElapsedTime() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
              let p = player else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Sleep Timer
    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepTimerEndOfTrack = false
        sleepTimerActive = true
        sleepTimerEndDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let endDate = self.sleepTimerEndDate else { return }
                if Date() >= endDate {
                    self.pause()
                    self.cancelSleepTimer()
                }
            }
    }

    func setSleepTimerEndOfTrack() {
        cancelSleepTimer()
        sleepTimerEndOfTrack = true
        sleepTimerActive = true
        sleepTimerEndDate = nil
    }

    func cancelSleepTimer() {
        sleepTimer?.cancel()
        sleepTimer = nil
        sleepTimerActive = false
        sleepTimerEndDate = nil
        sleepTimerEndOfTrack = false
    }

    var sleepTimerRemainingFormatted: String {
        if sleepTimerEndOfTrack { return "End of track" }
        guard let endDate = sleepTimerEndDate else { return "Off" }
        let remaining = max(endDate.timeIntervalSinceNow, 0)
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        return String(format: "%d:%02d", mins, secs)
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
        guard let song = currentSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let activePlayer = secondaryPlayer ?? player
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.albumTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: activePlayer?.currentTime ?? currentTime,
            MPMediaItemPropertyPlaybackDuration: activePlayer?.duration ?? duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0.0
        ]
        if let path = song.coverImageURL?.path, let image = ImageCache.shared.image(for: path) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote Command Center
    private func setupRemoteCommandCenter() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.resume() }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.next() }
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previous() }
            return .success
        }
        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let e = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            DispatchQueue.main.async { self.seek(to: e.positionTime) }
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
    func audioPlayerDidFinishPlaying(_ finishedPlayer: AVAudioPlayer, successfully flag: Bool) {
        // If this was the secondary player from a crossfade, ignore
        if finishedPlayer == secondaryPlayer { return }

        // If crossfade already advanced to a new song via autoAdvance,
        // ignore the old player's natural finish to prevent double-skip.
        // Check: if the current player is NOT the one that finished, someone else took over.
        if finishedPlayer !== player { return }

        // If we crossfaded, ignore natural ending of old player
        guard secondaryPlayer == nil else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Sleep timer: end of track mode
            if self.sleepTimerEndOfTrack {
                self.pause()
                self.cancelSleepTimer()
                return
            }

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
                    self.stop()
                }
            }
        }
    }
}

