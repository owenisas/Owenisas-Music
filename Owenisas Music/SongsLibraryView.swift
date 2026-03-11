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
    @State private var multiDeleteSelection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var showMultiDeleteConfirmation = false
    @State private var showNewPlaylistFromSelection = false
    @State private var newPlaylistName = ""

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

    private var selectedSongs: [SongData] {
        allSongs.filter { multiDeleteSelection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if allSongs.isEmpty {
                emptyState
            } else {
                sortBar
                songList
            }
        }
        .overlay(alignment: .bottom) {
            if editMode == .active {
                selectionToolbar
                    .padding(.bottom, 60) // Just above the tab bar
            }
        }
        .searchable(text: $searchText, prompt: "Search songs")
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                editButton
            }
        }
        .onChange(of: editMode) { _, newValue in
            withAnimation {
                player.showMiniPlayer = newValue == .inactive
            }
        }
        .onDisappear {
            player.showMiniPlayer = true
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
        .alert("Delete Selected Songs", isPresented: $showMultiDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                dataManager.deleteSongs(selectedSongs)
                multiDeleteSelection.removeAll()
                editMode = .inactive
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete \(multiDeleteSelection.count) songs? This cannot be undone.")
        }
        .alert("New Playlist", isPresented: $showNewPlaylistFromSelection) {
            TextField("Playlist Name", text: $newPlaylistName)
            Button("Create") { createPlaylistFromSelection() }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        } message: {
            Text("Enter a name for your new playlist.")
        }
    }

    private func createPlaylistFromSelection() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        
        let songs = selectedSongs
        let cover = songs.first?.coverImagePath
        
        if let playlist = dataManager.createPlaylist(title: name, coverImagePath: cover) {
            dataManager.addSongs(songs, to: playlist)
        }
        
        newPlaylistName = ""
        multiDeleteSelection.removeAll()
        editMode = .inactive
    }

    private var sortBar: some View {
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
    }

    private var songList: some View {
        List(selection: $multiDeleteSelection) {
            ForEach(filteredSongs, id: \.id) { songData in
                let song = Song.from(songData)
                SongRow(song: song, onAdd: {
                    songToAddToPlaylist = songData
                }, onRemove: {
                    songToDelete = songData
                    showDeleteConfirmation = true
                })
                .contentShape(Rectangle())
                .onTapGesture {
                    if editMode == .active {
                        if multiDeleteSelection.contains(songData.id) {
                            multiDeleteSelection.remove(songData.id)
                        } else {
                            multiDeleteSelection.insert(songData.id)
                        }
                    } else {
                        let allAsSongs = dataManager.toSongs(filteredSongs)
                        player.play(song: song, in: allAsSongs)
                    }
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                .tag(songData.id)
            }
            .onDelete(perform: deleteSongs)

            Color.clear
                .frame(height: 80)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
    }

    private var editButton: some View {
        Button(editMode == .inactive ? "Select" : "Done") {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                editMode = editMode == .inactive ? .active : .inactive
                if editMode == .inactive {
                    multiDeleteSelection.removeAll()
                }
            }
        }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 20) {
            Button(role: .destructive) {
                showMultiDeleteConfirmation = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 18))
                    Text("Delete")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.red)
            }
            .disabled(multiDeleteSelection.isEmpty)
            .opacity(multiDeleteSelection.isEmpty ? 0.5 : 1.0)
            
            Spacer()
            
            Text("\(multiDeleteSelection.count) Selected")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            
            Spacer()
            
            Button {
                showNewPlaylistFromSelection = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 18))
                    Text("Playlist+")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.green)
            }
            .disabled(multiDeleteSelection.isEmpty)
            .opacity(multiDeleteSelection.isEmpty ? 0.5 : 1.0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
        )
        .padding(.horizontal, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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

