import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var player = MusicPlayerManager.shared

    var body: some View {
        if let song = player.currentSong {
            VStack(spacing: 0) {
                // Thin progress bar at the top
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.green, .green.opacity(0.7)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * progressFraction)
                    }
                }
                .frame(height: 3)

                // Player content
                HStack(spacing: 12) {
                    // Song cover
                    if let uiImage = UIImage(contentsOfFile: song.coverImageURL.path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "music.note")
                                    .foregroundStyle(.white.opacity(0.5))
                            )
                    }

                    // Song info
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(song.artist)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }

                    Spacer()

                    // Play / Pause
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    // Next
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(
                ZStack {
                    // Blurred album art background
                    if let uiImage = UIImage(contentsOfFile: song.coverImageURL.path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 30)
                            .overlay(Color.black.opacity(0.6))
                    } else {
                        Color(white: 0.15)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                player.showFullPlayer = true
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var progressFraction: Double {
        guard player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }
}
