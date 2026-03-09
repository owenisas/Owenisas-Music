import SwiftUI
import SwiftData

struct ContentView: View {
    @ObservedObject var dataManager = DataManager.shared
    @ObservedObject var player = MusicPlayerManager.shared

    @Query(sort: \SongData.dateAdded, order: .reverse) private var allSongs: [SongData]
    @Query(sort: \PlaylistData.dateCreated, order: .reverse) private var playlists: [PlaylistData]
    @State private var songToAddToPlaylist: SongData?
    @State private var songToDelete: SongData?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                greetingHeader

                // Recently Added
                if !allSongs.isEmpty {
                    sectionHeader("Recently Added", icon: "clock.fill")
                    recentlyAddedCarousel
                }

                // Playlists
                sectionHeader("Your Playlists", icon: "music.note.list")
                playlistsSection

                // Quick Actions
                if !allSongs.isEmpty {
                    sectionHeader("All Songs", icon: "music.note")
                    allSongsSection
                }

                Spacer().frame(height: 100)
            }
            .padding(.horizontal, 16)
        }
        .background(Color(UIColor.systemBackground))
        .sheet(item: $songToAddToPlaylist) { songData in
            AddToPlaylistView(song: songData)
        }
        .alert("Delete Song", isPresented: $showDeleteConfirmation, presenting: songToDelete) { song in
            Button("Delete", role: .destructive) { dataManager.deleteSong(song) }
            Button("Cancel", role: .cancel) { songToDelete = nil }
        } message: { song in
            Text("Are you sure you want to delete '\(song.title)'? This will remove the files from your device.")
        }
    }

    // MARK: - Greeting
    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(.system(size: 28, weight: .bold, design: .rounded))

            if !allSongs.isEmpty {
                Text("\(allSongs.count) songs in your library")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 16)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good Morning ☀️"
        case 12..<17: return "Good Afternoon"
        case 17..<22: return "Good Evening 🌙"
        default:      return "Good Night 🌙"
        }
    }

    // MARK: - Section Header
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
        }
    }

    // MARK: - Recently Added
    private var recentlyAddedCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(allSongs.prefix(10), id: \.id) { songData in
                    let song = Song.from(songData)
                    Button {
                        player.play(song: song, in: dataManager.toSongs(allSongs))
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Group {
                                if let path = song.coverImageURL?.path, let uiImage = UIImage(contentsOfFile: path) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 150, height: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                } else {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [.blue.opacity(0.4), .purple.opacity(0.4)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 150, height: 150)
                                        .overlay(
                                            Image(systemName: "music.note")
                                                .font(.system(size: 32))
                                                .foregroundStyle(.white.opacity(0.5))
                                        )
                                }
                            }
                            .shadow(color: .black.opacity(0.15), radius: 6, y: 4)

                            Text(songData.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(songData.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 150)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            player.playNext(Song.from(songData))
                        } label: {
                            Label("Play Next", systemImage: "text.insert")
                        }

                        Button {
                            player.addToQueue(Song.from(songData))
                        } label: {
                            Label("Add to Queue", systemImage: "text.append")
                        }

                        Divider()

                        Button {
                            songToAddToPlaylist = songData
                        } label: {
                            Label("Add to Playlist", systemImage: "text.badge.plus")
                        }

                        Divider()

                        Button(role: .destructive) {
                            songToDelete = songData
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete from Library", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Playlists
    private var playlistsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                // Create new
                NavigationLink {
                    CreatePlaylistView()
                } label: {
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(UIColor.tertiarySystemFill))
                            .frame(width: 140, height: 140)
                            .overlay(
                                VStack(spacing: 6) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundStyle(.green)
                                    Text("New")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.green)
                                }
                            )

                        Text("Create Playlist")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(" ")
                            .font(.system(size: 10))
                    }
                    .frame(width: 140)
                }
                .buttonStyle(.plain)

                ForEach(playlists, id: \.id) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            playlistCoverSmall(playlist)
                                .frame(width: 140, height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 4)

                            Text(playlist.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text("\(playlist.songs.count) songs")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 140)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func playlistCoverSmall(_ playlist: PlaylistData) -> some View {
        let covers = playlist.songs.prefix(10).compactMap { song -> UIImage? in
            guard let path = song.coverImageURL?.path else { return nil }
            return UIImage(contentsOfFile: path)
        }

        return Group {
            if covers.count >= 4 {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 2),
                    GridItem(.flexible(), spacing: 2)
                ], spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        Image(uiImage: covers[i])
                            .resizable()
                            .scaledToFill()
                            .clipped()
                    }
                }
            } else if let first = covers.first {
                Image(uiImage: first)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.purple.opacity(0.4), .pink.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.6))
                    )
            }
        }
    }

    // MARK: - All Songs
    private var allSongsSection: some View {
        LazyVStack(spacing: 0) {
            // Play all / Shuffle all
            HStack(spacing: 12) {
                Button {
                    let songs = dataManager.toSongs(allSongs)
                    if let first = songs.first {
                        player.isShuffled = false
                        player.play(song: first, in: songs)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12))
                        Text("Play All")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.green, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Button {
                    let songs = dataManager.toSongs(allSongs)
                    if let first = songs.randomElement() {
                        player.isShuffled = true
                        player.play(song: first, in: songs)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 12))
                        Text("Shuffle")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.green.opacity(0.6), lineWidth: 1.5)
                    )
                }
            }
            .padding(.bottom, 14)

            ForEach(Array(allSongs.enumerated()), id: \.element.id) { index, songData in
                let song = Song.from(songData)
                SongRow(song: song, index: index + 1, onAdd: {
                    songToAddToPlaylist = songData
                }, onRemove: {
                    songToDelete = songData
                    showDeleteConfirmation = true
                })
                .onTapGesture {
                    player.play(song: song, in: dataManager.toSongs(allSongs))
                }

                if index < allSongs.count - 1 {
                    Divider()
                        .padding(.leading, 76)
                }
            }
        }
    }
}
