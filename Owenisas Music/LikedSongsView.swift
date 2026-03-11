import SwiftUI
import SwiftData

struct LikedSongsView: View {
    @Query(sort: \SongData.dateAdded, order: .reverse) private var allSongs: [SongData]
    @ObservedObject var player = MusicPlayerManager.shared
    @ObservedObject var dataManager = DataManager.shared

    var likedSongs: [SongData] {
        allSongs.filter { $0.isFavorited }
    }

    var songs: [Song] {
        dataManager.toSongs(likedSongs)
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
                trackList
            }
        }
        .listStyle(.plain)
        .background(Color(UIColor.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header
    private var headerSection: some View {
        VStack(spacing: 16) {
            // Heart cover
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [.pink.opacity(0.8), .red.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 220, height: 220)
                .overlay(
                    Image(systemName: "heart.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.white)
                )
                .shadow(color: .pink.opacity(0.3), radius: 16, x: 0, y: 8)

            Text("Liked Songs")
                .font(.title2.bold())

            Text("\(likedSongs.count) songs")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Controls
    private var controlsSection: some View {
        HStack(spacing: 20) {
            // Shuffle play
            Button {
                guard !songs.isEmpty else { return }
                player.isShuffled = true
                player.play(song: songs.randomElement()!, in: songs)
            } label: {
                HStack {
                    Image(systemName: "shuffle")
                    Text("Shuffle")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(.green, in: Capsule())
            }

            // Play
            Button {
                guard let first = songs.first else { return }
                player.isShuffled = false
                player.play(song: first, in: songs)
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.headline)
                .foregroundStyle(.green)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(
                    Capsule().stroke(.green, lineWidth: 2)
                )
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Track List
    private var trackList: some View {
        Group {
            if likedSongs.isEmpty {
                VStack(spacing: 12) {
                    Spacer().frame(height: 40)
                    Image(systemName: "heart")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("No liked songs yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Tap the heart icon on any song to add it here.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    let songData = likedSongs[index]
                    SongRow(song: song, index: index + 1, onRemove: {
                        toggleFavorite(songData: songData)
                    })
                    .contentShape(Rectangle())
                    .onTapGesture {
                        player.play(song: song, in: songs)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }

                // space for mini player
                Color.clear
                    .frame(height: 100)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }

    private func toggleFavorite(songData: SongData) {
        player.toggleFavorite(for: songData.id)
    }
}
