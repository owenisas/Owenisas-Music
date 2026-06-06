import SwiftUI
import SwiftData

/// "Your Stats" — a lightweight, Spotify-Wrapped-style summary of listening
/// activity derived entirely from on-device play counts and song durations.
struct StatsView: View {
    @Query private var allSongs: [SongData]
    @ObservedObject var player = MusicPlayerManager.shared
    @ObservedObject var dataManager = DataManager.shared

    // MARK: - Derived stats
    private var playedSongs: [SongData] {
        allSongs.filter { $0.playCount > 0 }
    }

    private var totalPlays: Int {
        playedSongs.reduce(0) { $0 + $1.playCount }
    }

    /// Estimated minutes listened: Σ(playCount × duration). Duration is known for
    /// downloaded songs; songs missing it simply contribute 0.
    private var estimatedMinutes: Int {
        let seconds = playedSongs.reduce(0.0) { $0 + Double($1.playCount) * $1.duration }
        return Int(seconds / 60)
    }

    /// Aggregated per-artist listening totals. A plain struct keeps the
    /// grouping cheap for the Swift type-checker (avoids slow tuple inference).
    struct ArtistStat: Identifiable {
        let name: String
        let plays: Int
        let coverURL: URL?
        var id: String { name }
    }

    private var topArtists: [ArtistStat] {
        let grouped = Dictionary(grouping: playedSongs, by: { $0.artist })
        var stats: [ArtistStat] = []
        for (name, songs) in grouped where name != "Unknown Artist" {
            let plays = songs.reduce(0) { $0 + $1.playCount }
            let cover = songs.max(by: { $0.playCount < $1.playCount })?.coverImageURL
            stats.append(ArtistStat(name: name, plays: plays, coverURL: cover))
        }
        return stats.sorted { $0.plays > $1.plays }
    }

    private var topSongs: [SongData] {
        playedSongs.sorted { $0.playCount > $1.playCount }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if playedSongs.isEmpty {
                    emptyState
                } else {
                    summaryCards
                    if let top = topArtists.first {
                        topArtistSpotlight(top)
                    }
                    topSongsSection
                    if topArtists.count > 1 {
                        topArtistsSection
                    }
                }
                Spacer().frame(height: 100)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle("Your Stats")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Summary Cards
    private var summaryCards: some View {
        HStack(spacing: 12) {
            statCard(value: "\(estimatedMinutes)", unit: "minutes", icon: "clock.fill", tint: .green)
            statCard(value: "\(totalPlays)", unit: "plays", icon: "play.circle.fill", tint: .blue)
            statCard(value: "\(playedSongs.count)", unit: "songs", icon: "music.note", tint: .pink)
        }
    }

    private func statCard(value: String, unit: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(unit)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 110)
        .padding(14)
        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Top Artist Spotlight
    private func topArtistSpotlight(_ artist: ArtistStat) -> some View {
        NavigationLink {
            ArtistDetailView(artistName: artist.name)
        } label: {
            HStack(spacing: 16) {
                if let url = artist.coverURL {
                    CachedCoverImage(url, size: 72, cornerRadius: 36)
                } else {
                    Circle()
                        .fill(Color(UIColor.tertiarySystemFill))
                        .frame(width: 72, height: 72)
                        .overlay(Image(systemName: "music.mic").foregroundStyle(.secondary))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("YOUR TOP ARTIST")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.green)
                    Text(artist.name)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(artist.plays) plays")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(
                LinearGradient(colors: [.green.opacity(0.18), .green.opacity(0.04)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Top Songs
    private var topSongsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Songs")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            let maxPlays = topSongs.first?.playCount ?? 1
            ForEach(Array(topSongs.prefix(10).enumerated()), id: \.element.id) { index, songData in
                let song = Song.from(songData)
                Button {
                    player.play(song: song, in: dataManager.toSongs(topSongs))
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(index < 3 ? .green : .secondary)
                            .frame(width: 24)

                        CachedCoverImage(song.coverImageURL, size: 44, cornerRadius: 8)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(songData.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            // Mini play-count bar
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color(UIColor.tertiarySystemFill)).frame(height: 4)
                                    Capsule().fill(.green)
                                        .frame(width: geo.size.width * CGFloat(songData.playCount) / CGFloat(max(maxPlays, 1)), height: 4)
                                }
                            }
                            .frame(height: 4)
                        }

                        Text("\(songData.playCount)×")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Top Artists list
    private var topArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Artists")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            ForEach(Array(topArtists.prefix(8).enumerated()), id: \.element.name) { index, artist in
                NavigationLink {
                    ArtistDetailView(artistName: artist.name)
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(index < 3 ? .green : .secondary)
                            .frame(width: 24)
                        if let url = artist.coverURL {
                            CachedCoverImage(url, size: 44, cornerRadius: 22)
                        } else {
                            Circle().fill(Color(UIColor.tertiarySystemFill)).frame(width: 44, height: 44)
                                .overlay(Image(systemName: "music.mic").font(.system(size: 14)).foregroundStyle(.secondary))
                        }
                        Text(artist.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(artist.plays) plays")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 80)
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 52))
                .foregroundStyle(
                    LinearGradient(colors: [.green, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text("No stats yet")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Play some songs and your\nlistening stats will appear here")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
