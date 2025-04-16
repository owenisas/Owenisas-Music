import SwiftUI

struct SongRow: View {
    let song: Song
    @ObservedObject var playerManager = MusicPlayerManager.shared
    
    var body: some View {
        HStack {
            // Display cover image
            if let uiImage = UIImage(contentsOfFile: song.coverImageURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 50, height: 50)
                    .clipped()
                    .cornerRadius(4)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 50, height: 50)
            }
            
            Text(song.title)
                .font(.headline)
            Spacer()
            
            // If this song is currently playing, show Pause and Stop; otherwise, show Play.
            if playerManager.currentSong?.id == song.id && playerManager.isPlaying {
                HStack(spacing: 16) {
                    Button(action: {
                        playerManager.pause()
                    }) {
                        Image(systemName: "pause.circle.fill")
                            .font(.title)
                    }
                    Button(action: {
                        playerManager.stop()
                    }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title)
                    }
                }
            } else {
                Button(action: {
                    playerManager.play(song: song)
                }) {
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview("SongRow Preview") {
    // Dummy preview (replace paths with valid ones if testing on a device)
    let dummySong = Song(
        title: "Test Song",
        audioFileURL: URL(fileURLWithPath: "/path/to/audio.mp3"),
        coverImageURL: URL(fileURLWithPath: "/path/to/cover.png")
    )
    SongRow(song: dummySong)
}
