import AVFoundation
import Combine
import MediaPlayer
import SwiftUI  // Required for UIImage

class MusicPlayerManager: NSObject, ObservableObject {
    static let shared = MusicPlayerManager()
    
    private var player: AVAudioPlayer?
    @Published var isPlaying = false
    @Published var currentSong: Song? = nil  // Currently playing song
    
    override init() {
        super.init()
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: []  // Use .mixWithOthers if you want to allow other audio
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Error setting up audio session: \(error)")
        }
        setupRemoteCommandCenter()
    }
    
    func play(song: Song) {
        stop()  // Stop any ongoing playback.
        currentSong = song
        do {
            player = try AVAudioPlayer(contentsOf: song.audioFileURL)
            player?.delegate = self  // Set delegate to catch playback finished events.
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
    
    // MARK: Remote Command Setup
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        // Play command
        commandCenter.playCommand.addTarget { [unowned self] event in
            if let _ = self.currentSong, !self.isPlaying {
                self.player?.play()
                self.isPlaying = true
                self.updateNowPlayingInfo()
                return .success
            }
            return .commandFailed
        }
        // Pause command
        commandCenter.pauseCommand.addTarget { [unowned self] event in
            if self.isPlaying {
                self.player?.pause()
                self.isPlaying = false
                self.updateNowPlayingInfo()
                return .success
            }
            return .commandFailed
        }
    }
    
    // MARK: Now Playing Info
    
    private func updateNowPlayingInfo(clear: Bool = false) {
        if clear {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        guard let song = currentSong, let player = player else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        
        // Add artwork if available.
        if let image = UIImage(contentsOfFile: song.coverImageURL.path) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { size in
                return image
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}

// MARK: - AVAudioPlayerDelegate

extension MusicPlayerManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("Finished playing")
        // Optionally you can implement auto-advance functionality here.
        updateNowPlayingInfo(clear: true)
    }
}
