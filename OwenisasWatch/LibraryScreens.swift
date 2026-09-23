import SwiftUI

/// Loads a phone list page by page as rows scroll into view.
@MainActor
final class PagedListModel<Item: Codable & Equatable & Identifiable>: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var total: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var error: PhoneLink.LinkError?

    private var nextOffset: Int? = 0
    private let fetch: (PhoneLink, Int) async throws -> WatchPage<Item>

    init(fetch: @escaping (PhoneLink, Int) async throws -> WatchPage<Item>) {
        self.fetch = fetch
    }

    func loadFirstPage(_ phone: PhoneLink) async {
        guard items.isEmpty, total == nil else { return }
        await loadNext(phone)
    }

    /// Fetch the next page when `item` is among the last few rows.
    func loadMore(after item: Item, _ phone: PhoneLink) async {
        guard let position = items.lastIndex(where: { $0.id == item.id }),
              position >= items.count - 5 else { return }
        await loadNext(phone)
    }

    func reload(_ phone: PhoneLink) async {
        items = []
        total = nil
        nextOffset = 0
        error = nil
        await loadNext(phone)
    }

    private func loadNext(_ phone: PhoneLink) async {
        guard let offset = nextOffset, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await fetch(phone, offset)
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            total = page.total
            nextOffset = page.nextOffset
            error = nil
        } catch let failure as PhoneLink.LinkError {
            error = failure
        } catch {
            self.error = .other(error.localizedDescription)
        }
    }
}

/// Songs of a phone list (Liked Songs, a playlist, Recently Added).
struct SongListScreen: View {
    let list: WatchListRef
    let title: String

    @EnvironmentObject private var phone: PhoneLink
    @EnvironmentObject private var offline: OfflineLibrary
    @EnvironmentObject private var router: WatchRouter
    @StateObject private var model: PagedListModel<WatchSongItem>
    @State private var playError: String?

    init(list: WatchListRef, title: String) {
        self.list = list
        self.title = title
        _model = StateObject(wrappedValue: PagedListModel { phone, offset in
            try await phone.songPage(list, offset: offset)
        })
    }

    var body: some View {
        List {
            if list.isDownloadable {
                DownloadControl(list: list, title: title)
            }

            if model.items.isEmpty {
                placeholder
            } else {
                ForEach(model.items) { song in
                    Button {
                        play(song)
                    } label: {
                        SongRowView(
                            songID: song.id,
                            title: song.title,
                            artist: song.artist,
                            trailingSystemImage: badge(for: song)
                        )
                    }
                    .onAppear {
                        Task { await model.loadMore(after: song, phone) }
                    }
                }
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if let error = model.error {
                    PhoneUnavailableView(message: error.errorDescription ?? "") {
                        Task { await model.loadMore(after: model.items[model.items.count - 1], phone) }
                    }
                }
            }
        }
        .navigationTitle(title)
        .containerBackground(Color.owenisasGreen.gradient, for: .navigation)
        .overlay(alignment: .bottom) { ErrorToast(message: $playError) }
        .task { await model.loadFirstPage(phone) }
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.isLoading || (model.total == nil && model.error == nil) {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else if let error = model.error {
            PhoneUnavailableView(message: error.errorDescription ?? "") {
                Task { await model.reload(phone) }
            }
        } else {
            switch list {
            case .liked:
                EmptyStateView(systemImage: "heart", title: "No Liked Songs", message: "Songs you like on your iPhone show up here.")
            case .recentlyAdded:
                EmptyStateView(systemImage: "clock", title: "No Songs Yet", message: "Add music on your iPhone.")
            case .playlist:
                EmptyStateView(systemImage: "music.note.list", title: "Empty Playlist")
            }
        }
    }

    private func badge(for song: WatchSongItem) -> String? {
        if phone.nowPlaying?.songID == song.id { return "speaker.wave.2.fill" }
        if offline.index.tracks[song.id] != nil { return "arrow.down.circle.fill" }
        return nil
    }

    private func play(_ song: WatchSongItem) {
        router.show(.phoneNowPlaying)
        Task {
            do {
                try await phone.play(song, in: list)
            } catch {
                playError = error.localizedDescription
            }
        }
    }
}

struct PlaylistsScreen: View {
    @EnvironmentObject private var phone: PhoneLink
    @EnvironmentObject private var offline: OfflineLibrary
    @StateObject private var model = PagedListModel<WatchPlaylistItem> { phone, offset in
        try await phone.playlistPage(offset: offset)
    }

    var body: some View {
        List {
            if model.items.isEmpty {
                if model.isLoading || (model.total == nil && model.error == nil) {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if let error = model.error {
                    PhoneUnavailableView(message: error.errorDescription ?? "") {
                        Task { await model.reload(phone) }
                    }
                } else {
                    EmptyStateView(systemImage: "music.note.list", title: "No Playlists", message: "Create playlists on your iPhone.")
                }
            } else {
                ForEach(model.items) { playlist in
                    NavigationLink(value: WatchRoute.songs(playlist.list, title: playlist.title)) {
                        PlaylistRowView(playlist: playlist, state: offline.state(for: playlist.list))
                    }
                    .onAppear {
                        Task { await model.loadMore(after: playlist, phone) }
                    }
                }
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Playlists")
        .containerBackground(Color.owenisasGreen.gradient, for: .navigation)
        .task { await model.loadFirstPage(phone) }
    }
}

struct PlaylistRowView: View {
    let playlist: WatchPlaylistItem
    let state: WatchOfflineState

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(songID: playlist.artworkSongID, size: 32, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.title)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .lineLimit(1)
                Text(playlist.songCount == 1 ? "1 song" : "\(playlist.songCount) songs")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            OfflineBadge(state: state)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small download-state glyph for rows.
struct OfflineBadge: View {
    let state: WatchOfflineState

    var body: some View {
        switch state {
        case .notDownloaded:
            EmptyView()
        case .downloading:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Color.owenisasGreen)
                .accessibilityLabel("Downloading to watch")
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.owenisasGreen)
                .accessibilityLabel("On watch")
        case .incomplete:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.yellow)
                .accessibilityLabel("Some songs didn't download")
        }
    }
}

#Preview("Liked Songs") {
    NavigationStack {
        SongListScreen(list: .liked, title: "Liked Songs")
    }
    .environmentObject(PhoneLink.preview())
    .environmentObject(OfflineLibrary.preview())
    .environmentObject(WatchLocalPlayer.preview())
    .environmentObject(WatchRouter())
    .tint(.owenisasGreen)
}

#Preview("Playlists") {
    NavigationStack {
        PlaylistsScreen()
    }
    .environmentObject(PhoneLink.preview())
    .environmentObject(OfflineLibrary.preview())
    .tint(.owenisasGreen)
}
