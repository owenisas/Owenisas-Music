import SwiftUI
import SwiftData

struct SongsLibraryView: View {
    @ObservedObject var dataManager = DataManager.shared
    @ObservedObject var player = MusicPlayerManager.shared
    @State private var allSongs: [SongData] = []
    @State private var searchText = ""
    @State private var sortOption: SortOption = .dateAdded

    enum SortOption: String, CaseIterable {
        case dateAdded = "Recently Added"
        case title = "Title"
        case artist = "Artist"
    }

    var filteredSongs: [SongData] {
        var songs = allSongs

        // Apply search filter
        if !searchText.isEmpty {
            songs = songs.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.artist.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Apply sort
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
                // Sort picker
                HStack {
                    Text("\(allSongs.count) Songs")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Menu {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Button {
                                sortOption = option
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
                            Text(sortOption.rawValue)
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // Song list
                List {
                    ForEach(filteredSongs, id: \.id) { songData in
                        let song = Song.from(songData)
                        SongRow(song: song)
                            .onTapGesture {
                                let allAsSongs = dataManager.toSongs(filteredSongs)
                                player.play(song: song, in: allAsSongs)
                            }
                            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                    }
                    .onDelete(perform: deleteSongs)

                    // Bottom spacer for mini player
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
        .onAppear { refreshData() }
        .onReceive(NotificationCenter.default.publisher(for: .init("SongsFolderChanged"))) { _ in
            dataManager.syncFromFileSystem()
            refreshData()
        }
    }

    private func refreshData() {
        allSongs = dataManager.fetchAllSongs()
    }

    private func deleteSongs(at offsets: IndexSet) {
        let songsToDelete = offsets.map { filteredSongs[$0] }
        for song in songsToDelete {
            dataManager.deleteSong(song)
        }
        refreshData()
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "music.note.house")
                .font(.system(size: 60))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.green, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Your library is empty")
                .font(.title3.bold())

            Text("Download songs from YouTube\nto start building your collection")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }
}
