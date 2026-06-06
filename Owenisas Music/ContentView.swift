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

    private var recentlyPlayed: [SongData] {
        allSongs
            .filter { $0.lastPlayedDate != nil }
            .sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }
    }

    // MARK: - "Made For You" mixes
    private var hasEnoughForMixes: Bool { allSongs.count >= 4 }

    /// Most-played songs first.
    private var onRepeatMix: [SongData] {
        allSongs.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }
    }

    /// A blend of liked, most-played, and the rest of the library (deduped).
    private var dailyMix: [SongData] {
        var seen = Set<String>()
        var result: [SongData] = []
        for song in allSongs.filter({ $0.isFavorited }) + onRepeatMix + allSongs {
            if seen.insert(song.id).inserted { result.append(song) }
        }
        return Array(result.prefix(50))
    }

    /// Songs you've played the least — surface forgotten tracks.
    private var discoverMix: [SongData] {
        allSongs.sorted { $0.playCount < $1.playCount }
    }

    private func playMix(_ songs: [SongData]) {
        let pool = dataManager.toSongs(songs)
        guard let first = pool.randomElement() else { return }
        player.isShuffled = true
        player.play(song: first, in: pool)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                greetingHeader

                // Recently Played
                if !recentlyPlayed.isEmpty {
                    sectionHeader("Recently Played", icon: "clock.arrow.circlepath")
                    recentlyPlayedCarousel
                }

                // Made For You
                if hasEnoughForMixes {
                    sectionHeader("Made For You", icon: "sparkles")
                    madeForYouSection
                }

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
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
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting)
                    .font(.system(size: 26, weight: .bold, design: .rounded))

                if !allSongs.isEmpty {
                    Text("\(allSongs.count) songs in your library")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
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

    // MARK: - Made For You
    private var madeForYouSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                mixCard(
                    title: "Daily Mix",
                    subtitle: "A blend just for you",
                    icon: "infinity",
                    gradient: [.green, .teal],
                    songs: dailyMix
                )

                if !onRepeatMix.isEmpty {
                    mixCard(
                        title: "On Repeat",
                        subtitle: "Your most played",
                        icon: "repeat",
                        gradient: [.purple, .indigo],
                        songs: onRepeatMix
                    )
                }

                mixCard(
                    title: "Discover",
                    subtitle: "Rediscover your library",
                    icon: "safari",
                    gradient: [.orange, .pink],
                    songs: discoverMix
                )
            }
        }
    }

    private func mixCard(title: String, subtitle: String, icon: String, gradient: [Color], songs: [SongData]) -> some View {
        Button {
            playMix(songs)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(14)
            .frame(width: 150, height: 150, alignment: .leading)
            .background(
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(10)
            }
            .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recently Played
    private var recentlyPlayedCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(Array(recentlyPlayed.prefix(8).enumerated()), id: \.offset) { _, songData in
                    let song = Song.from(songData)
                    Button {
                        player.play(song: song, in: dataManager.toSongs(recentlyPlayed))
                    } label: {
                        HStack(spacing: 10) {
                            CachedCoverImage(song.coverImageURL, size: 48, cornerRadius: 6)

                            Text(songData.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)

                            Spacer()
                        }
                        .frame(width: 180)
                        .padding(8)
                        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            player.toggleFavorite(for: songData.id)
                        } label: {
                            Label(songData.isFavorited ? "Unlike" : "Like", systemImage: songData.isFavorited ? "heart.slash" : "heart")
                        }

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
                    }
                }
            }
        }
    }

    // MARK: - Recently Added
    private var recentlyAddedCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(Array(allSongs.prefix(10).enumerated()), id: \.offset) { _, songData in
                    let song = Song.from(songData)
                    Button {
                        player.play(song: song, in: dataManager.toSongs(allSongs))
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CachedCoverImage(song.coverImageURL, size: 150, cornerRadius: 12)
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
                            player.toggleFavorite(for: songData.id)
                        } label: {
                            Label(songData.isFavorited ? "Unlike" : "Like", systemImage: songData.isFavorited ? "heart.slash" : "heart")
                        }

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

                // Liked Songs pseudo-playlist
                NavigationLink {
                    LikedSongsView()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.pink.opacity(0.8), .red.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 140, height: 140)
                            .overlay(
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.white)
                            )
                            .shadow(color: .pink.opacity(0.3), radius: 6, y: 4)

                        Text("Liked Songs")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text("Auto-Playlist")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
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
        let urls = Array(playlist.songs.compactMap { $0.coverImageURL }.prefix(4))

        return Group {
            if urls.count >= 4 {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 2),
                    GridItem(.flexible(), spacing: 2)
                ], spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        CachedCoverImage(urls[i], size: 70, cornerRadius: 0)
                            .clipped()
                    }
                }
            } else if let first = urls.first {
                CachedCoverImage(first, size: 140, cornerRadius: 0)
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

            ForEach(Array(allSongs.enumerated()), id: \.offset) { index, songData in
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
