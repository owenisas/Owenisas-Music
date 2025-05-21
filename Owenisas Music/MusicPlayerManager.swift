import AVFoundation
import Combine
import MediaPlayer
import UIKit

class MusicPlayerManager: NSObject, ObservableObject {
    static let shared = MusicPlayerManager()
    
    private var player: AVAudioPlayer?
    @Published var isPlaying = false
    @Published var currentSong: Song? = nil  // Currently playing song
    /// Playlist to enable next‐song autoplay
    private var playlist: [Song] = []
    
    override init() {
        super.init()
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: []  // Use .mixWithOthers to mix with other audio
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Error setting up audio session: \(error)")
        }
        setupRemoteCommandCenter()
    }
    
    /// Play a song, optionally setting a new playlist for autoplay
    func play(song: Song, in playlist: [Song]? = nil) {
        // If a new playlist is provided, replace it
        if let list = playlist {
            self.playlist = list
        }
        stop()
        currentSong = song
        do {
            player = try AVAudioPlayer(contentsOf: song.audioFileURL)
            player?.delegate = self
            player?.prepareToPlay()
            player?.play()
            isPlaying = true
            updateNowPlayingInfo()
        } catch {
            print("Error playing song \(song.title): \(error)")
        }
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }
    
    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentSong = nil
        updateNowPlayingInfo(clear: true)
    }
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self,
                  let _ = self.currentSong,
                  !self.isPlaying else {
                return .commandFailed
            }
            self.player?.play()
            self.isPlaying = true
            self.updateNowPlayingInfo()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self,
                  self.isPlaying else {
                return .commandFailed
            }
            self.player?.pause()
            self.isPlaying = false
            self.updateNowPlayingInfo()
            return .success
        }
    }
    
    private func updateNowPlayingInfo(clear: Bool = false) {
        if clear {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        guard let song = currentSong,
              let player = player else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let image = UIImage(contentsOfFile: song.coverImageURL.path) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}

extension MusicPlayerManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Autoplay next song in playlist
        if let current = currentSong,
           let index = playlist.firstIndex(where: { $0.id == current.id }),
           playlist.indices.contains(index + 1) {
            let nextSong = playlist[index + 1]
            play(song: nextSong)  // continues autoplay
        } else {
            // No next song: clear info
            updateNowPlayingInfo(clear: true)
            isPlaying = false
            currentSong = nil
        }
    }
}

