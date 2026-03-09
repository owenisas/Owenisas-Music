import SwiftUI
import SwiftData

struct PlaylistDetailView: View {
    @Bindable var playlist: PlaylistData
    @ObservedObject var player = MusicPlayerManager.shared
    @ObservedObject var dataManager = DataManager.shared
    @State private var showAddSongs = false
    @State private var showRenameAlert = false
    @State private var newName = ""

    var songs: [Song] {
        dataManager.toSongs(playlist.songs)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    EditButton()
                        .foregroundStyle(.green)
                    
                    Menu {
                        Button {
                            newName = playlist.title
                            showRenameAlert = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        
                        Button(role: .destructive) {
                            dataManager.deletePlaylist(playlist)
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSongs) {
            AddSongsToPlaylistView(playlist: playlist)
        }
        .alert("Rename Playlist", isPresented: $showRenameAlert) {
            TextField("Playlist name", text: $newName)
            Button("Save") {
                dataManager.renamePlaylist(playlist, to: newName)
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        VStack(spacing: 16) {
            // Playlist cover (mosaic of first 4 songs or placeholder)
            playlistCover
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 8)

            Text(playlist.title)
                .font(.title2.bold())

            Text("\(playlist.songs.count) songs")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private var playlistCover: some View {
        let covers = playlist.songs.prefix(10).compactMap { song -> UIImage? in
            guard let path = song.coverImageURL?.path else { return nil }
            return UIImage(contentsOfFile: path)
        }

        return Group {
            if covers.count >= 4 {
                // 2x2 grid
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
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
                            colors: [.purple.opacity(0.6), .blue.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.system(size: 50))
                            .foregroundStyle(.white.opacity(0.7))
                    )
            }
        }
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
    }

    // MARK: - Track List
    private var trackList: some View {
        Group {
            HStack {
                Button {
                    showAddSongs = true
                } label: {
                    Label("Add Songs", systemImage: "plus.circle.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.green)
                }
                Spacer()
            }
            .listRowSeparator(.hidden)
            .padding(.bottom, 8)

            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                let songData = playlist.songs[index]
                SongRow(song: song, index: index + 1, onRemove: {
                    dataManager.removeSong(songData, from: playlist)
                })
                    .contentShape(Rectangle())
                    .onTapGesture {
                        player.play(song: song, in: songs)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            .onDelete(perform: deleteSongs)
            .onMove(perform: moveSongs)

            // space for mini player
            Color.clear
                .frame(height: 100)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    private func deleteSongs(at offsets: IndexSet) {
        let songsToRemove = offsets.map { playlist.songs[$0] }
        for songData in songsToRemove {
            dataManager.removeSong(songData, from: playlist)
        }
    }

    private func moveSongs(from source: IndexSet, to destination: Int) {
        playlist.songs.move(fromOffsets: source, toOffset: destination)
        try? dataManager.modelContext?.save()
    }
}

// MARK: - Add Songs to Playlist
struct AddSongsToPlaylistView: View {
    @Bindable var playlist: PlaylistData
    @ObservedObject var dataManager = DataManager.shared
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \SongData.dateAdded, order: .reverse) private var allSongs: [SongData]

    var body: some View {
        NavigationView {
            List(allSongs, id: \.id) { songData in
                let isAlreadyAdded = playlist.songs.contains { $0.id == songData.id }

                HStack {
                    // Cover
                    if let path = songData.coverImageURL?.path, let uiImage = UIImage(contentsOfFile: path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 44, height: 44)
                            .overlay(Image(systemName: "music.note").font(.caption))
                    }

                    VStack(alignment: .leading) {
                        Text(songData.title)
                            .font(.body)
                        Text(songData.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isAlreadyAdded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            dataManager.addSong(songData, to: playlist)
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.title3)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
