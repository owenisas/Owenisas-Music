import SwiftUI

extension View {
    /// Reserve room for the mini player at the bottom of a tab's content, so
    /// the last rows of every screen scroll clear of it (no hard-coded spacers).
    func miniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerView()
                .padding(.bottom, 6)
        }
    }
}

struct MiniPlayerView: View {
    @ObservedObject var player = MusicPlayerManager.shared

    var body: some View {
        if player.showMiniPlayer, let song = player.currentSong {
            VStack(spacing: 0) {
                // Thin progress line
                PlaybackProgressLine(player: player, songID: song.id, isPlaying: player.isPlaying)
                    .frame(height: 2.5)

                HStack(spacing: 12) {
                    CachedCoverImage(song.coverImageURL, size: 46, cornerRadius: 8)
                        .shadow(color: .white.opacity(0.08), radius: 8)
                        .id(song.id)
                        .transition(.opacity)

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
                    .id("title-\(song.id)")
                    .transition(.opacity)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens the full player")

                    Spacer(minLength: 4)

                    // Favorite button
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        player.toggleFavorite()
                    } label: {
                        Image(systemName: song.isFavorited ? "heart.fill" : "heart")
                            .font(.system(size: 15))
                            .foregroundStyle(song.isFavorited ? .pink : .white.opacity(0.5))
                            .frame(width: 40, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(song.isFavorited ? "Remove from Liked Songs" : "Add to Liked Songs")

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("miniPlayerPlayPause")
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 40, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next song")
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
                .animation(.easeOut(duration: 0.2), value: song.id)
            }
            .background(MiniPlayerBackgroundView(path: song.coverImageURL?.path))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                player.showFullPlayer = true
            }
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        if value.translation.height < -30 {
                            player.showFullPlayer = true
                        }
                    }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Progress line that polls the player only while it's on screen and playing.
/// Lives in its own view so the ticking doesn't re-render the whole mini player,
/// and it snaps (no backwards sweep) when the song changes.
struct PlaybackProgressLine: View {
    let player: MusicPlayerManager
    let songID: String
    /// Passed in (not read off `player`) so a play/pause change is a new
    /// input and SwiftUI re-evaluates the paused state — otherwise the line
    /// stayed frozen after pressing play.
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !isPlaying)) { _ in
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.white.opacity(0.08))
                    Rectangle()
                        .fill(LinearGradient(colors: [.green, .green.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * fraction)
                }
            }
        }
        .transaction { $0.animation = nil }
        .id(songID)
        .accessibilityHidden(true)
    }

    private var fraction: CGFloat {
        let duration = player.duration
        let time = player.currentTime
        guard duration.isFinite, duration > 0, time.isFinite else { return 0 }
        return CGFloat(min(max(time / duration, 0), 1))
    }
}

struct MiniPlayerBackgroundView: View {
    let path: String?
    @State private var uiImage: UIImage?

    var body: some View {
        Group {
            if let uiImage = uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 40)
                    .overlay(Color.black.opacity(0.65))
                    .drawingGroup()
            } else {
                Color(white: 0.1)
            }
        }
        // A slow load for an earlier song can't overwrite the current one.
        .task(id: path) {
            guard let path else {
                uiImage = nil
                return
            }
            if let cached = ImageCache.shared.cachedThumbnail(for: path, pointSize: 64) {
                uiImage = cached
                return
            }
            let img = await Task.detached(priority: .utility) {
                ImageCache.shared.thumbnail(for: path, pointSize: 64)
            }.value
            guard !Task.isCancelled else { return }
            uiImage = img
        }
    }
}
