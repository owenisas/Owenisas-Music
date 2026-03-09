import SwiftUI
import SwiftData

struct ContentView: View {
    @ObservedObject var dataManager = DataManager.shared
    @ObservedObject var player = MusicPlayerManager.shared
    @State private var allSongs: [SongData] = []
    @State private var playlists: [PlaylistData] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Greeting header
                greetingHeader

                // Recently Added
                if !allSongs.isEmpty {
                    sectionHeader("Recently Added", icon: "clock.fill")
                    recentlyAddedCarousel
                }

                // Your Playlists
                sectionHeader("Your Playlists", icon: "music.note.list")
                playlistsSection

                // All Songs
                if !allSongs.isEmpty {
                    sectionHeader("All Songs", icon: "music.note")
                    allSongsSection
                }

                Spacer().frame(height: 100) // padding for mini player
            }
            .padding(.horizontal, 16)
        }
        .background(Color(UIColor.systemBackground))
        .onAppear { refreshData() }
        .onReceive(NotificationCenter.default.publisher(for: .init("SongsFolderChanged"))) { _ in
            dataManager.syncFromFileSystem()
            refreshData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("PlaylistsChanged"))) { _ in
            refreshData()
        }
    }

    private func refreshData() {
        allSongs = dataManager.fetchAllSongs()
        playlists = dataManager.fetchAllPlaylists()
    }

    // MARK: - Greeting
    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.title.bold())

            Text("\(allSongs.count) songs in your library")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 16)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good Morning"
        case 12..<17: return "Good Afternoon"
        case 17..<22: return "Good Evening"
        default:      return "Good Night"
        }
    }

    // MARK: - Section Header
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.green)
            Text(title)
                .font(.title3.bold())
        }
    }

    // MARK: - Recently Added Carousel
    private var recentlyAddedCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(allSongs.prefix(10), id: \.id) { songData in
                    let song = Song.from(songData)
                    Button {
                        player.play(song: song, in: dataManager.toSongs(allSongs))
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let uiImage = UIImage(contentsOfFile: songData.coverImageURL.path) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 140, height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        LinearGradient(
                                            colors: [.blue.opacity(0.5), .purple.opacity(0.5)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 140, height: 140)
                                    .overlay(
                                        Image(systemName: "music.note")
                                            .font(.largeTitle)
                                            .foregroundStyle(.white.opacity(0.6))
                                    )
                            }

                            Text(songData.title)
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(songData.artist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 140)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Playlists
    private var playlistsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                // Create new playlist card
                NavigationLink {
                    CreatePlaylistView()
                } label: {
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(white: 0.15))
                            .frame(width: 130, height: 130)
                            .overlay(
                                VStack(spacing: 6) {
                                    Image(systemName: "plus")
                                        .font(.title)
                                        .foregroundStyle(.green)
                                    Text("New")
                                        .font(.caption.bold())
                                        .foregroundStyle(.green)
                                }
                            )

                        Text("Create Playlist")
                            .font(.caption.bold())
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(" ")
                            .font(.caption2)
                    }
                    .frame(width: 130)
                }
                .buttonStyle(.plain)

                // Existing playlists
                ForEach(playlists, id: \.id) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            playlistCoverSmall(playlist)
                                .frame(width: 130, height: 130)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            Text(playlist.title)
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text("\(playlist.songs.count) songs")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 130)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func playlistCoverSmall(_ playlist: PlaylistData) -> some View {
        let covers = playlist.songs.prefix(4).compactMap { song -> UIImage? in
            UIImage(contentsOfFile: song.coverImageURL.path)
        }

        return Group {
            if covers.count >= 4 {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 1),
                    GridItem(.flexible(), spacing: 1)
                ], spacing: 1) {
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
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [.purple.opacity(0.5), .pink.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.7))
                    )
            }
        }
    }

    // MARK: - All Songs
    private var allSongsSection: some View {
        VStack(spacing: 0) {
            // Play all / Shuffle all
            HStack(spacing: 14) {
                Button {
                    let songs = dataManager.toSongs(allSongs)
                    if let first = songs.first {
                        player.play(song: first, in: songs)
                    }
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Play All")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.green, in: Capsule())
                }

                Button {
                    var songs = dataManager.toSongs(allSongs)
                    songs.shuffle()
                    if let first = songs.first {
                        player.play(song: first, in: songs)
                    }
                } label: {
                    HStack {
                        Image(systemName: "shuffle")
                        Text("Shuffle")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().stroke(.green, lineWidth: 1.5)
                    )
                }
            }
            .padding(.bottom, 12)

            ForEach(Array(allSongs.enumerated()), id: \.element.id) { index, songData in
                let song = Song.from(songData)
                SongRow(song: song, index: index + 1)
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
