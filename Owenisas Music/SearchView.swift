import SwiftUI
import SwiftData

struct SearchView: View {
    @ObservedObject var player = MusicPlayerManager.shared
    @ObservedObject var dataManager = DataManager.shared
    @Query(sort: \SongData.dateAdded, order: .reverse) private var allSongs: [SongData]
    @Query(sort: \PlaylistData.dateCreated, order: .reverse) private var playlists: [PlaylistData]

    @State private var searchText = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    // Recent searches (persisted, newline-delimited, most-recent first)
    @AppStorage("recentSearchHistory") private var recentSearchHistoryRaw = ""
    private let maxRecentSearches = 8

    private var recentSearches: [String] {
        recentSearchHistoryRaw
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func addRecentSearch(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var items = recentSearches.filter { $0.localizedCaseInsensitiveCompare(trimmed) != .orderedSame }
        items.insert(trimmed, at: 0)
        recentSearchHistoryRaw = items.prefix(maxRecentSearches).joined(separator: "\n")
    }

    private func removeRecentSearch(_ term: String) {
        recentSearchHistoryRaw = recentSearches
            .filter { $0 != term }
            .joined(separator: "\n")
    }

    private func clearRecentSearches() {
        recentSearchHistoryRaw = ""
    }

    private var filteredSongs: [SongData] {
        guard !searchText.isEmpty else { return [] }
        return allSongs.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText) ||
            $0.albumTitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredArtists: [String] {
        guard !searchText.isEmpty else { return [] }
        let artists = Set(allSongs.map(\.artist))
        return artists
            .filter { $0.localizedCaseInsensitiveContains(searchText) }
            .sorted()
    }

    private var filteredPlaylists: [PlaylistData] {
        guard !searchText.isEmpty else { return [] }
        return playlists.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var uniqueArtists: [(name: String, songCount: Int, coverURL: URL?)] {
        let grouped = Dictionary(grouping: allSongs, by: \.artist)
        return grouped.map { (name: $0.key, songCount: $0.value.count, coverURL: $0.value.first?.coverImageURL) }
            .sorted { $0.songCount > $1.songCount }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                searchBar

                if searchText.isEmpty {
                    browseContent
                } else {
                    searchResults
                }

                Spacer().frame(height: 100)
            }
        }
        .background(Color(UIColor.systemBackground))
        .navigationBarHidden(true)
    }

    // MARK: - Search Bar
    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("Songs, artists, playlists", text: $searchText)
                    .font(.system(size: 16))
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { addRecentSearch(searchText) }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSearching = true
                        }
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if isSearching {
                Button("Cancel") {
                    searchText = ""
                    searchFocused = false
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSearching = false
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.green)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    // MARK: - Recent Searches
    @ViewBuilder
    private var recentSearchesSection: some View {
        if !recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent Searches")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Spacer()
                    Button("Clear") {
                        withAnimation { clearRecentSearches() }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                }
                .padding(.horizontal, 16)

                ForEach(recentSearches, id: \.self) { term in
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text(term)
                            .font(.system(size: 15))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            withAnimation { removeRecentSearch(term) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        searchText = term
                        searchFocused = true
                        withAnimation(.easeInOut(duration: 0.2)) { isSearching = true }
                    }
                }
            }
        }
    }

    // MARK: - Browse Content (when not searching)
    private var browseContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            recentSearchesSection

            Text("Browse")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .padding(.horizontal, 16)

            // Genre/Category Cards
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                NavigationLink {
                    SongsLibraryView()
                } label: {
                    BrowseCategoryCard(title: "All Songs", icon: "music.note", gradient: [.green, .mint])
                }
                .buttonStyle(.plain)

                NavigationLink {
                    LikedSongsView()
                } label: {
                    BrowseCategoryCard(title: "Liked Songs", icon: "heart.fill", gradient: [.pink, .red])
                }
                .buttonStyle(.plain)

                NavigationLink {
                    RecentlyPlayedView()
                } label: {
                    BrowseCategoryCard(title: "Recently Played", icon: "clock.fill", gradient: [.blue, .indigo])
                }
                .buttonStyle(.plain)

                NavigationLink {
                    MostPlayedView()
                } label: {
                    BrowseCategoryCard(title: "Most Played", icon: "flame.fill", gradient: [.orange, .red])
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            // Artists Section
            if !uniqueArtists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Artists")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(uniqueArtists.prefix(10), id: \.name) { artist in
                                NavigationLink {
                                    ArtistDetailView(artistName: artist.name)
                                } label: {
                                    VStack(spacing: 8) {
                                        if let url = artist.coverURL {
                                            CachedCoverImage(url, size: 80, cornerRadius: 40)
                                        } else {
                                            Circle()
                                                .fill(Color(UIColor.tertiarySystemFill))
                                                .frame(width: 80, height: 80)
                                                .overlay(
                                                    Image(systemName: "music.mic")
                                                        .font(.system(size: 24))
                                                        .foregroundStyle(.secondary)
                                                )
                                        }

                                        Text(artist.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .frame(width: 80)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    // MARK: - Search Results
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 20) {
            if filteredSongs.isEmpty && filteredArtists.isEmpty && filteredPlaylists.isEmpty {
                VStack(spacing: 12) {
                    Spacer().frame(height: 60)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("No results for \"\(searchText)\"")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                // Artists
                if !filteredArtists.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Artists")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        ForEach(filteredArtists.prefix(3), id: \.self) { artist in
                            NavigationLink {
                                ArtistDetailView(artistName: artist)
                            } label: {
                                HStack(spacing: 12) {
                                    let coverURL = allSongs.first(where: { $0.artist == artist })?.coverImageURL
                                    if let url = coverURL {
                                        CachedCoverImage(url, size: 48, cornerRadius: 24)
                                    } else {
                                        Circle()
                                            .fill(Color(UIColor.tertiarySystemFill))
                                            .frame(width: 48, height: 48)
                                            .overlay(
                                                Image(systemName: "music.mic")
                                                    .foregroundStyle(.secondary)
                                            )
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(artist)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.primary)
                                        Text("Artist")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Songs
                if !filteredSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Songs")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        ForEach(filteredSongs.prefix(10), id: \.id) { songData in
                            let song = Song.from(songData)
                            SongRow(song: song)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    addRecentSearch(searchText)
                                    player.play(song: song, in: dataManager.toSongs(filteredSongs))
                                }
                        }
                    }
                }

                // Playlists
                if !filteredPlaylists.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Playlists")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        ForEach(filteredPlaylists, id: \.id) { playlist in
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [.purple.opacity(0.5), .blue.opacity(0.5)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 48, height: 48)
                                        .overlay(
                                            Image(systemName: "music.note.list")
                                                .font(.system(size: 16))
                                                .foregroundStyle(.white)
                                        )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.title)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.primary)
                                        Text("\(playlist.songs.count) songs")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

}

// MARK: - Browse Category Card
struct BrowseCategoryCard: View {
    let title: String
    let icon: String
    let gradient: [Color]

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(14)
        .frame(height: 90)
        .background(
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
