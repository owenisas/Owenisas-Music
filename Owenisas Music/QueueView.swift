import SwiftUI

struct QueueView: View {
    @ObservedObject var player = MusicPlayerManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()

                if player.queue.isEmpty {
                    emptyState
                } else {
                    List {
                        // Now Playing Section
                        if let current = player.currentSong {
                            Section {
                                HStack(spacing: 12) {
                                    coverThumb(for: current)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(current.title)
                                            .font(.system(size: 15, weight: .semibold))
                                            .lineLimit(1)
                                        Text(current.artist)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    NowPlayingBars()
                                        .frame(width: 20, height: 16)
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(Color.green.opacity(0.08))
                            } header: {
                                Text("Now Playing")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.green)
                                    .textCase(nil)
                            }
                        }

                        // Up Next Section
                        Section {
                            let upNext = Array(player.queue.suffix(from: min(player.currentIndex + 1, player.queue.count)))
                            if upNext.isEmpty {
                                HStack {
                                    Spacer()
                                    VStack(spacing: 8) {
                                        Image(systemName: "text.append")
                                            .font(.title2)
                                            .foregroundStyle(.secondary)
                                        Text("Queue is empty")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 20)
                                    Spacer()
                                }
                                .listRowBackground(Color.clear)
                            } else {
                                ForEach(Array(upNext.enumerated()), id: \.element.id) { index, song in
                                    HStack(spacing: 12) {
                                        coverThumb(for: song)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(song.title)
                                                .font(.system(size: 15, weight: .medium))
                                                .lineLimit(1)
                                            Text(song.artist)
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        let realIndex = player.currentIndex + 1 + index
                                        if realIndex < player.queue.count {
                                            player.play(song: player.queue[realIndex], in: nil)
                                        }
                                    }
                                }
                                .onMove(perform: moveSongs)
                                .onDelete(perform: deleteSongs)
                            }
                        } header: {
                            HStack {
                                Text("Up Next")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .textCase(nil)
                                Spacer()
                                let count = max(player.queue.count - player.currentIndex - 1, 0)
                                if count > 0 {
                                    Text("\(count) songs")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .textCase(nil)
                                }
                            }
                        }

                        // Spacer for safe area
                        Color.clear
                            .frame(height: 60)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.insetGrouped)
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    // MARK: - Cover Thumbnail
    @ViewBuilder
    private func coverThumb(for song: Song) -> some View {
        CachedCoverImage(song.coverImageURL, size: 42, cornerRadius: 6)
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Nothing in the queue")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Play a song to get started")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Queue Actions
    private func moveSongs(from source: IndexSet, to destination: Int) {
        let offset = player.currentIndex + 1
        let correctedSource = IndexSet(source.map { $0 + offset })
        let correctedDestination = destination + offset
        player.moveInQueue(from: correctedSource, to: correctedDestination)
    }

    private func deleteSongs(at offsets: IndexSet) {
        let offset = player.currentIndex + 1
        let correctedOffsets = IndexSet(offsets.map { $0 + offset })
        player.removeFromQueue(at: correctedOffsets)
    }
}
