import Foundation

/// A per-render search snapshot: callers reuse the results for section checks,
/// rows and playback rather than re-scanning the library for each access.
/// Not persisted, so edits/imports/deletions reflected by @Query remain current.
@MainActor
struct LibrarySearchResults {
    let songs: [SongData]
    let artists: [String]
    let playlists: [PlaylistData]

    init(songs: [SongData], playlists: [PlaylistData], text: String) {
        guard !text.isEmpty else {
            self.songs = []
            self.artists = []
            self.playlists = []
            return
        }
        self.songs = songs.filter {
            $0.title.localizedCaseInsensitiveContains(text) ||
            $0.artist.localizedCaseInsensitiveContains(text) ||
            $0.albumTitle.localizedCaseInsensitiveContains(text)
        }
        self.artists = Set(songs.map(\.artist))
            .filter { $0.localizedCaseInsensitiveContains(text) }
            .sorted()
        self.playlists = playlists.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }
}
