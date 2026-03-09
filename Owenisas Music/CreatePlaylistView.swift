import SwiftUI
import SwiftData

struct CreatePlaylistView: View {
    @ObservedObject var dataManager = DataManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var playlistName = ""
    @State private var selectedSongIDs: Set<String> = []

    var allSongs: [SongData] {
        dataManager.fetchAllSongs()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Playlist name input
            VStack(spacing: 16) {
                // Playlist icon
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [.green.opacity(0.6), .blue.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: .green.opacity(0.3), radius: 12, x: 0, y: 6)

                TextField("Playlist Name", text: $playlistName)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)

            // Song selection
            if allSongs.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No songs in your library")
                        .foregroundStyle(.secondary)
                    Text("Download some songs first!")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                Text("Add songs to your playlist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)

                List(allSongs, id: \.id) { songData in
                    let isSelected = selectedSongIDs.contains(songData.id)

                    HStack(spacing: 12) {
                        // Cover
                        if let uiImage = UIImage(contentsOfFile: songData.coverImageURL.path) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .foregroundStyle(.secondary)
                                )
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(songData.title)
                                .font(.body)
                                .lineLimit(1)
                            Text(songData.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? .green : .secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSelected {
                            selectedSongIDs.remove(songData.id)
                        } else {
                            selectedSongIDs.insert(songData.id)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("New Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Create") {
                    createPlaylist()
                }
                .font(.headline)
                .foregroundStyle(.green)
                .disabled(playlistName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func createPlaylist() {
        let trimmed = playlistName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if let playlist = dataManager.createPlaylist(title: trimmed) {
            let songs = allSongs.filter { selectedSongIDs.contains($0.id) }
            for song in songs {
                dataManager.addSong(song, to: playlist)
            }
        }
        dismiss()
    }
}
