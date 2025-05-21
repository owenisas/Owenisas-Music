import SwiftUI

struct ControlCenterView: View {
    @ObservedObject private var player = MusicPlayerManager.shared
    
    var body: some View {
        if let song = player.currentSong {
            VStack(spacing: 8) {
                Text(song.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                // Progress slider
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { new in player.seek(to: new) }
                    ),
                    in: 0...player.duration
                )
                
                HStack(spacing: 40) {
                    // Previous
                    Button {
                        player.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title2)
                    }
                    // Play / Pause
                    Button {
                        player.isPlaying
                            ? player.pause()
                            : player.play(
                                song: song,
                                in: player.playlist
                              )
                    } label: {
                        Image(systemName: player.isPlaying
                                ? "pause.fill" : "play.fill")
                            .font(.largeTitle)
                    }
                    // Next
                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title2)
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(12)
            .padding([.horizontal, .bottom])
        }
    }
}

#Preview("ControlCenterView Preview") {
    ControlCenterView()
        .previewLayout(.sizeThatFits)
}

