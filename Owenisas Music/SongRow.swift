import SwiftUI

struct SongRow: View {
    let song: Song
    let index: Int?
    var showAlbumArt: Bool = true
    var onAdd: (() -> Void)?
    var onRemove: (() -> Void)?
    @ObservedObject var playerManager = MusicPlayerManager.shared

    init(song: Song, index: Int? = nil, showAlbumArt: Bool = true, onAdd: (() -> Void)? = nil, onRemove: (() -> Void)? = nil) {
        self.song = song
        self.index = index
        self.showAlbumArt = showAlbumArt
        self.onAdd = onAdd
        self.onRemove = onRemove
    }

    private var isCurrentlyPlaying: Bool {
        playerManager.currentSong?.id == song.id
    }

    var body: some View {
        HStack(spacing: 12) {
            if let idx = index, !showAlbumArt {
                Text("\(idx)")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(isCurrentlyPlaying ? .green : .secondary)
                    .frame(width: 28)
            }

            if showAlbumArt {
                CachedCoverImage(song.coverImageURL, size: 48, cornerRadius: 8)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(song.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isCurrentlyPlaying ? .green : .primary)
                        .lineLimit(1)
                    
                    if song.isFavorited {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.pink)
                    }
                }

                Text(song.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isCurrentlyPlaying && playerManager.isPlaying {
                NowPlayingBars()
                    .frame(width: 20, height: 16)
            }

            Menu {
                Button {
                    playerManager.toggleFavorite(for: song.id)
                } label: {
                    Label(song.isFavorited ? "Unlike" : "Like", systemImage: song.isFavorited ? "heart.slash" : "heart")
                }

                Button {
                    playerManager.playNext(song)
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }

                Button {
                    playerManager.addToQueue(song)
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }

                if onAdd != nil || onRemove != nil {
                    Divider()
                }

                if let onAdd = onAdd {
                    Button {
                        onAdd()
                    } label: {
                        Label("Add to Playlist", systemImage: "text.badge.plus")
                    }
                }

                if let onRemove = onRemove {
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Animated "Now Playing" Bars
struct NowPlayingBars: View {
    @State private var heights: [CGFloat] = [0.4, 0.6, 0.3]
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.green)
                    .frame(width: 3)
                    .scaleEffect(y: heights[i], anchor: .bottom)
            }
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.35)) {
                heights = (0..<3).map { _ in CGFloat.random(in: 0.25...1.0) }
            }
        }
    }
}
