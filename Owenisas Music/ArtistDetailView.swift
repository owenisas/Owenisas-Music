import SwiftUI
import SwiftData

struct ArtistDetailView: View {
    let artistName: String
    @ObservedObject var player = MusicPlayerManager.shared
    @ObservedObject var dataManager = DataManager.shared
    @Query(sort: \SongData.dateAdded, order: .reverse) private var allSongs: [SongData]
    @State private var songToAddToPlaylist: SongData?

    private var artistSongs: [SongData] {
        allSongs.filter { $0.artist == artistName }
    }

    private var songs: [Song] {
        dataManager.toSongs(artistSongs)
    }

    private var coverURL: URL? {
        artistSongs.first?.coverImageURL
    }

    var body: some View {
        List {
            Section {
                headerSection
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                controlsSection
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(Array(zip(artistSongs, songs).enumerated()), id: \.offset) { index, pair in
                    let (songData, song) = pair
                    SongRow(song: song, index: index + 1, onAdd: {
                        songToAddToPlaylist = songData
                    })
                    .contentShape(Rectangle())
                    .onTapGesture {
                        player.play(song: song, in: songs)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }

                Color.clear
                    .frame(height: 100)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .background(Color(UIColor.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $songToAddToPlaylist) { songData in
            AddToPlaylistView(song: songData)
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        VStack(spacing: 16) {
            if let url = coverURL {
                CachedCoverImage(url, size: 160, cornerRadius: 80)
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            } else {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.gray.opacity(0.4), .gray.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 160, height: 160)
                    .overlay(
                        Image(systemName: "music.mic")
                            .font(.system(size: 56))
                            .foregroundStyle(.white.opacity(0.6))
                    )
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            }

            Text(artistName)
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("\(artistSongs.count) songs")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Controls
    private var controlsSection: some View {
        HStack(spacing: 16) {
            Button {
                guard !songs.isEmpty else { return }
                player.isShuffled = true
                player.play(song: songs.randomElement()!, in: songs)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Shuffle")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(.green, in: Capsule())
            }

            Button {
                guard let first = songs.first else { return }
                player.isShuffled = false
                player.play(song: first, in: songs)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Play")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Capsule().stroke(.green, lineWidth: 1.5))
            }
        }
        .padding(.vertical, 12)
    }
}
