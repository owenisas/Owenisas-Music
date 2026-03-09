import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var player = MusicPlayerManager.shared

    var body: some View {
        if let song = player.currentSong {
            VStack(spacing: 0) {
                // Thin progress line
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(.white.opacity(0.08))
                        Rectangle()
                            .fill(.white.opacity(0.6))
                            .frame(width: geo.size.width * progressFraction)
                            .animation(.linear(duration: 0.25), value: progressFraction)
                    }
                }
                .frame(height: 2.5)

                HStack(spacing: 12) {
                    CachedCoverImage(song.coverImageURL, size: 46, cornerRadius: 8)
                        .shadow(color: .white.opacity(0.08), radius: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(song.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(miniPlayerBackground(song: song))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                player.showFullPlayer = true
            }
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            ))
        }
    }

    @ViewBuilder
    private func miniPlayerBackground(song: Song) -> some View {
        if let path = song.coverImageURL?.path, let uiImage = ImageCache.shared.image(for: path) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .blur(radius: 40)
                .overlay(Color.black.opacity(0.65))
        } else {
            Color(white: 0.1)
        }
    }

    private var progressFraction: Double {
        guard player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }
}
