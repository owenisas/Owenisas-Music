import Foundation

/// Snapshot of the player state, persisted so a relaunch can pick up
/// exactly where the listener left off (paused, never auto-playing).
struct PlaybackSession: Codable, Equatable {
    var queueIDs: [String]
    var originalQueueIDs: [String]
    var currentSongID: String
    var position: TimeInterval
    var isShuffled: Bool
    var repeatModeRaw: Int
}

/// Tiny UserDefaults-backed store for the playback session.
/// The payload is a few KB of song IDs at most, so UserDefaults is plenty.
enum PlaybackSessionStore {
    private static let key = "playbackSession.v1"

    static func save(_ session: PlaybackSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> PlaybackSession? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PlaybackSession.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
