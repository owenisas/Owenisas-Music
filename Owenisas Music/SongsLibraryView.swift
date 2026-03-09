import SwiftUI
import SwiftData

struct SongsLibraryView: View {
    @ObservedObject var dataManager = DataManager.shared
    @ObservedObject var player = MusicPlayerManager.shared

    @Query(sort: \SongData.dateAdded, order: .reverse) private var allSongs: [SongData]
    @State private var searchText = ""
    @State private var sortOption: SortOption = .dateAdded
    @State private var songToAddToPlaylist: SongData?
    @State private var songToDelete: SongData?
    @State private var showDeleteConfirmation = false

    enum SortOption: String, CaseIterable {
        case dateAdded = "Recently Added"
        case title = "Title"
        case artist = "Artist"
    }

    var filteredSongs: [SongData] {
        var songs = allSongs

        if !searchText.isEmpty {
            songs = songs.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.artist.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch sortOption {
        case .dateAdded:
            songs.sort { $0.dateAdded > $1.dateAdded }
        case .title:
            songs.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .artist:
            songs.sort { $0.artist.localizedCompare($1.artist) == .orderedAscending }
        }

        return songs
    }

    var body: some View {
        VStack(spacing: 0) {
            if allSongs.isEmpty {
                emptyState
            } else {
                // Sort bar
                HStack {
                    Text("\(allSongs.count) Songs")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Menu {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    sortOption = option
                                }
                            } label: {
                                HStack {
                                    Text(option.rawValue)
                                    if sortOption == option {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 11, weight: .bold))
                            Text(sortOption.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.1), in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // Song list
                List {
                    ForEach(filteredSongs, id: \.id) { songData in
                        let song = Song.from(songData)
                        SongRow(song: song, onAdd: {
                            songToAddToPlaylist = songData
                        }, onRemove: {
                            songToDelete = songData
                            showDeleteConfirmation = true
                        })
                        .onTapGesture {
                            let allAsSongs = dataManager.toSongs(filteredSongs)
                            player.play(song: song, in: allAsSongs)
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                    }
                    .onDelete(perform: deleteSongs)

                    Color.clear
                        .frame(height: 80)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $searchText, prompt: "Search songs")
        .navigationTitle("Library")
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

    private func deleteSongs(at offsets: IndexSet) {
        if let index = offsets.first {
            songToDelete = filteredSongs[index]
            showDeleteConfirmation = true
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.house")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.green, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Your library is empty")
                .font(.system(size: 20, weight: .bold, design: .rounded))

            Text("Download songs from YouTube\nto start building your collection")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }
}
