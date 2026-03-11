import SwiftUI
import SwiftData

struct AddToPlaylistView: View {
    @ObservedObject var dataManager = DataManager.shared
    @Environment(\.dismiss) private var dismiss
    let song: SongData
    
    @Query(sort: \PlaylistData.dateCreated, order: .reverse) private var playlists: [PlaylistData]

    var body: some View {
        NavigationStack {
            Group {
                if playlists.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No playlists found")
                            .foregroundStyle(.secondary)
                        Text("Create one first!")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    List(playlists, id: \.id) { playlist in
                        let isAlreadyAdded = playlist.songs.contains { $0.id == song.id }
                        
                        HStack(spacing: 12) {
                            // Small Playlist Cover logic
                            if let firstSong = playlist.songs.first {
                                CachedCoverImage(firstSong.coverImageURL, size: 44, cornerRadius: 4)
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        LinearGradient(
                                            colors: [.purple.opacity(0.6), .blue.opacity(0.6)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Image(systemName: "music.note.list")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.8))
                                    )
                            }

                            VStack(alignment: .leading) {
                                Text(playlist.title)
                                    .font(.body)
                                    .lineLimit(1)
                                Text("\(playlist.songs.count) songs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            if isAlreadyAdded {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.green)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isAlreadyAdded {
                                dataManager.addSong(song, to: playlist)
                                dismiss() // Dismiss automatically after adding
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
