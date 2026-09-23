import AVFoundation
import Foundation
import MediaPlayer

/// Plays downloaded music on the watch itself. watchOS only routes
/// long-form audio to Bluetooth (headphones/speakers); `activate(options:)`
/// shows the route picker when none is connected.
@MainActor
final class WatchLocalPlayer: NSObject, ObservableObject {
    static let shared = WatchLocalPlayer()

    @Published private(set) var queue: [WatchOfflineTrack] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isActivating = false
    @Published private(set) var duration: Double = 0
    /// Why playback couldn't start (no Bluetooth route, unreadable file).
    @Published var problem: String?

    private var player: AVAudioPlayer?
    private var sessionActive = false
    private var observers: [NSObjectProtocol] = []
    private let isPreview: Bool

    var current: WatchOfflineTrack? { queue.indices.contains(index) ? queue[index] : nil }
    var currentTime: Double { player?.currentTime ?? 0 }
    var hasTrack: Bool { current != nil }

    private override init() {
        isPreview = false
        super.init()
        observeSession()
        setUpRemoteCommands()
    }

    private init(preview track: WatchOfflineTrack) {
        isPreview = true
        super.init()
        queue = [track]
        duration = track.duration
        isPlaying = true
    }

    static func preview() -> WatchLocalPlayer {
        WatchLocalPlayer(preview: PreviewFixtures.offlineTracks[0])
    }

    // MARK: - Transport

    func play(_ tracks: [WatchOfflineTrack], startAt start: Int = 0, shuffled: Bool = false) async {
        guard !tracks.isEmpty else { return }
        var list = tracks
        var first = min(max(start, 0), tracks.count - 1)
        if shuffled {
            list.shuffle()
            first = 0
        }
        stopPlayer()
        queue = list
        index = first
        await startCurrent()
    }

    func togglePlayPause() async {
        if isPlaying {
            pause()
        } else {
            await resume()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume() async {
        guard current != nil else { return }
        guard await activateSession() else { return }
        if player == nil {
            await startCurrent()
            return
        }
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func next() async {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            index += 1
            await startCurrent()
        } else {
            // End of the list: cue the first song, paused.
            stopPlayer()
            index = 0
            updateNowPlayingInfo()
        }
    }

    func previous() async {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard index > 0 else {
            seek(to: 0)
            return
        }
        index -= 1
        await startCurrent()
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds), player.duration)
        updateNowPlayingInfo()
    }

    func stop() {
        stopPlayer()
        queue = []
        index = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateSession()
    }

    /// Drop tracks whose files were removed from the watch.
    func forget(_ removedIDs: Set<String>) {
        guard !removedIDs.isEmpty, queue.contains(where: { removedIDs.contains($0.id) }) else { return }
        if let current, removedIDs.contains(current.id) {
            stop()
        } else {
            let currentID = current?.id
            queue.removeAll { removedIDs.contains($0.id) }
            index = queue.firstIndex { $0.id == currentID } ?? 0
        }
    }

    // MARK: - Playback

    private func startCurrent() async {
        guard let track = current else { return }
        guard await activateSession() else { return }
        stopPlayer()
        let url = OfflineLibrary.shared.fileURL(for: track)
        do {
            let hint = WatchFileNaming.sanitizedExtension(url.pathExtension) == "m4a" ? AVFileType.m4a.rawValue : nil
            let player = try AVAudioPlayer(contentsOf: url, fileTypeHint: hint)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            duration = player.duration
            isPlaying = true
            problem = nil
            updateNowPlayingInfo()
        } catch {
            NSLog("OWENISAS_WATCH: can't play %@: %@", track.title, "\(error)")
            problem = "Couldn't play \(track.title)."
            isPlaying = false
        }
    }

    private func stopPlayer() {
        player?.delegate = nil
        player?.stop()
        player = nil
        isPlaying = false
        duration = current?.duration ?? 0
    }

    // MARK: - Audio session

    /// Long-form audio needs a Bluetooth route. `activate(options:)` picks
    /// one automatically when possible and otherwise shows the route picker.
    private func activateSession() async -> Bool {
        if isPreview { return true }
        if sessionActive { return true }
        let session = AVAudioSession.sharedInstance()
        isActivating = true
        defer { isActivating = false }
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            let activated = try await session.activate(options: [])
            sessionActive = activated
            if !activated {
                problem = "Connect Bluetooth headphones to listen on your watch."
            }
            return activated
        } catch {
            NSLog("OWENISAS_WATCH: audio session activation failed: %@", "\(error)")
            problem = "Connect Bluetooth headphones to listen on your watch."
            return false
        }
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        sessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
            Task { @MainActor in
                // The system may have deactivated the session.
                self?.sessionActive = false
                self?.pause()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            // Headphones disconnected: pause instead of going silent.
            guard raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.pause() }
        })
    }

    // MARK: - System now playing / remote commands

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.previous() }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard !isPreview else { return }
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: player?.duration ?? track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
        ]
    }
}

extension WatchLocalPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.player else { return }
            await self.next()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard player === self.player else { return }
            self.problem = "Couldn't play \(self.current?.title ?? "this song")."
            await self.next()
        }
    }
}
