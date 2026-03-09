import SwiftUI

struct SongRow: View {
    let song: Song
    let index: Int?
    var showAlbumArt: Bool = true
    @ObservedObject var playerManager = MusicPlayerManager.shared

    init(song: Song, index: Int? = nil, showAlbumArt: Bool = true) {
        self.song = song
        self.index = index
        self.showAlbumArt = showAlbumArt
    }

    private var isCurrentlyPlaying: Bool {
        playerManager.currentSong?.id == song.id
    }

    var body: some View {
        HStack(spacing: 12) {
            // Track number or album art
            if let idx = index, !showAlbumArt {
                Text("\(idx)")
                    .font(.subheadline)
                    .foregroundStyle(isCurrentlyPlaying ? .green : .secondary)
                    .frame(width: 28)
            }

            if showAlbumArt {
                coverImage
            }

            // Song info
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isCurrentlyPlaying ? .green : .primary)
                    .lineLimit(1)

                Text(song.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Playing indicator
            if isCurrentlyPlaying && playerManager.isPlaying {
                NowPlayingBars()
                    .frame(width: 20, height: 16)
            }

            // More button
            Menu {
                Button {
                    // Add to playlist - handled by parent
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }

                Button(role: .destructive) {
                    // Delete - handled by parent
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var coverImage: some View {
        Group {
            if let uiImage = UIImage(contentsOfFile: song.coverImageURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [.gray.opacity(0.4), .gray.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundStyle(.white.opacity(0.6))
                    )
            }
        }
    }
}

// MARK: - Animated "Now Playing" Bars
struct NowPlayingBars: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.green)
                    .frame(width: 3)
                    .scaleEffect(y: animate ? CGFloat.random(in: 0.3...1.0) : 0.4, anchor: .bottom)
            }
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 0.5)
                .repeatForever(autoreverses: true)
            ) {
                animate = true
            }
        }
    }
}
