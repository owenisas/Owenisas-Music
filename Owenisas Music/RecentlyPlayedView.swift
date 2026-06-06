import SwiftUI
import SwiftData

struct RecentlyPlayedView: View {
    @ObservedObject var player = MusicPlayerManager.shared
    @ObservedObject var dataManager = DataManager.shared
    @Query(sort: \SongData.dateAdded, order: .reverse) private var allSongs: [SongData]
    @State private var songToAddToPlaylist: SongData?

    private var recentlyPlayed: [SongData] {
        allSongs
            .filter { $0.lastPlayedDate != nil }
            .sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }
    }

    private var songs: [Song] {
        dataManager.toSongs(recentlyPlayed)
    }

    var body: some View {
        List {
            Section {
                headerSection
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                if !songs.isEmpty {
                    controlsSection
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                if recentlyPlayed.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(Array(zip(recentlyPlayed, songs).enumerated()), id: \.offset) { index, pair in
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
        }
        .listStyle(.plain)
        .background(Color(UIColor.systemBackground))
        .navigationTitle("Recently Played")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $songToAddToPlaylist) { songData in
            AddToPlaylistView(song: songData)
        }
    }

    private var headerSection: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.8), .indigo.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 180, height: 180)
                .overlay(
                    Image(systemName: "clock.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.white)
                )
                .shadow(color: .blue.opacity(0.3), radius: 16, y: 8)

            Text("Recently Played")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text("\(recentlyPlayed.count) songs")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 40)
            Image(systemName: "clock")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No listening history yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Songs you've played will appear here")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
