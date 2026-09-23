import Foundation

/// Sample data for SwiftUI previews.
enum PreviewFixtures {
    static let songs: [WatchSongItem] = [
        WatchSongItem(id: "s1", title: "Midnight City Lights", artist: "Neon Harbor", duration: 241, isFavorited: true, bytes: nil, hasArtwork: false),
        WatchSongItem(id: "s2", title: "Paper Boats", artist: "The Quiet Hours", duration: 198, isFavorited: true, bytes: nil, hasArtwork: false),
        WatchSongItem(id: "s3", title: "A Very Long Song Title That Needs Truncating", artist: "Somebody With A Long Name", duration: 3720, isFavorited: false, bytes: nil, hasArtwork: false),
        WatchSongItem(id: "s4", title: "Low Tide", artist: "Marrow", duration: 176, isFavorited: false, bytes: nil, hasArtwork: false),
    ]

    static let playlists: [WatchPlaylistItem] = [
        WatchPlaylistItem(id: "p1", title: "Night Drive", songCount: 24, artworkSongID: "s1"),
        WatchPlaylistItem(id: "p2", title: "Focus", songCount: 1, artworkSongID: nil),
    ]

    static let nowPlaying = WatchNowPlaying(
        songID: "s1", title: "Midnight City Lights", artist: "Neon Harbor",
        isPlaying: true, isFavorited: true, duration: 241, elapsed: 64, rate: 1,
        capturedAt: Date(), queueIndex: 0, queueCount: 12
    )

    static let offlineTracks: [WatchOfflineTrack] = songs.prefix(3).map {
        WatchOfflineTrack(
            id: $0.id, title: $0.title, artist: $0.artist, duration: $0.duration,
            bytes: 7_200_000, fileName: WatchFileNaming.fileName(songID: $0.id, fileExtension: "m4a"),
            addedAt: Date()
        )
    }

    static let offlineIndex: WatchOfflineIndex = {
        var index = WatchOfflineIndex()
        let requested = songs.map { song -> WatchSongItem in
            var copy = song
            copy.bytes = 7_200_000
            return copy
        }
        index.upsertCollection(list: .liked, title: "Liked Songs", manifestOrder: songs.map(\.id), requested: requested, present: [])
        index.upsertCollection(list: .playlist("p1"), title: "Night Drive", manifestOrder: ["s1", "s2"], requested: Array(requested.prefix(2)), present: [])
        for track in offlineTracks { index.recordArrival(track) }
        return index
    }()
}
