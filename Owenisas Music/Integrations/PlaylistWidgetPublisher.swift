import Foundation
import WidgetKit

@MainActor
final class PlaylistWidgetPublisher {
    static let shared = PlaylistWidgetPublisher()
    private var observers: [NSObjectProtocol] = []
    func start() {
        guard observers.isEmpty else { return }
        for name in ["PlaylistsChanged", "SongsFolderChanged", "LibraryFavoriteChanged", "LibrarySongIndexed", "LibrarySongsDeleted", "LibraryBackupImported"] {
            observers.append(NotificationCenter.default.addObserver(forName: .init(name), object: nil, queue: .main) { _ in
                Task { @MainActor in Self.shared.refresh() }
            })
        }
        refresh()
    }
    func refresh() {
        let dm = DataManager.shared
        guard dm.modelContext != nil else { return } // Never overwrite a real catalog with a cold empty store.
        let liked = PlaylistWidgetItem(id: "liked", title: "Liked Songs", songCount: dm.fetchAllSongs().filter(\.isFavorited).count)
        let items = [liked] + dm.fetchAllPlaylists().map { PlaylistWidgetItem(id: "playlist:" + $0.id, title: $0.title, songCount: $0.orderedSongs.count) }
        do {
            try PlaylistWidgetStore.save(PlaylistWidgetCatalog(items: items, capturedAt: Date()))
            WidgetCenter.shared.reloadTimelines(ofKind: PlaylistWidgetStore.kind)
        } catch { NSLog("Playlist widget unavailable: %@", error.localizedDescription) }
    }
    enum PlaybackError: LocalizedError {
        case notReady, missing, empty
        var errorDescription: String? {
            switch self {
            case .notReady: "Open Owenisas Music to load your library."
            case .missing: "This playlist was removed. Edit the widget to choose another."
            case .empty: "This list has no playable downloaded songs."
            }
        }
    }
    static func play(id: String) throws {
        let dm = DataManager.shared
        guard dm.modelContext != nil else { throw PlaybackError.notReady }
        let data: [SongData]
        if id == "liked" { data = dm.fetchAllSongs().filter(\.isFavorited) }
        else {
            guard id.hasPrefix("playlist:"), let playlist = dm.fetchAllPlaylists().first(where: { "playlist:" + $0.id == id }) else { throw PlaybackError.missing }
            data = playlist.orderedSongs
        }
        let playable = data.filter { FileManager.default.fileExists(atPath: $0.audioFileURL.path) }
        let songs = dm.toSongs(playable)
        guard let first = songs.first else { throw PlaybackError.empty }
        MusicPlayerManager.shared.play(song: first, in: songs)
    }
}
