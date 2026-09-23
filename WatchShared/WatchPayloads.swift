import Foundation

// Codable payloads carried in `WatchEnvelope` bodies. Keep them small: a
// WatchConnectivity message or reply must stay under ~64 KB.

// MARK: - Limits

enum WatchLimits {
    /// WatchConnectivity rejects messages above ~65 KB; leave headroom for
    /// the envelope.
    static let maxPayloadBytes = 56_000
    static let defaultPageSize = 20
    static let maxPageSize = 25
    /// Songs one "Download to Watch" can cover (keeps the manifest small).
    static let maxDownloadSongs = 200
    /// "Recently Added" on the watch is the newest N songs.
    static let maxRecentlyAdded = 200
    /// Titles/artists are cut to this many characters on the wire.
    static let maxTextLength = 80

    static func trimmed(_ text: String, max: Int = maxTextLength) -> String {
        text.count <= max ? text : String(text.prefix(max - 1)) + "…"
    }
}

enum WatchArtworkSize {
    /// Thumbnails are small JPEGs, at most this many pixels on the long side.
    static let thumbnail = 80

    static func clamped(_ requested: Int) -> Int {
        min(max(requested, 16), thumbnail)
    }
}

// MARK: - Lists

/// A song list on the phone the watch can browse, play from, or download.
enum WatchListRef: Hashable, Codable, Identifiable, CustomStringConvertible {
    case liked
    case recentlyAdded
    case playlist(String)

    var rawValue: String {
        switch self {
        case .liked: return "liked"
        case .recentlyAdded: return "recent"
        case .playlist(let id): return "playlist:" + id
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "liked": self = .liked
        case "recent": self = .recentlyAdded
        default:
            let prefix = "playlist:"
            guard rawValue.hasPrefix(prefix), rawValue.count > prefix.count else { return nil }
            self = .playlist(String(rawValue.dropFirst(prefix.count)))
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let ref = WatchListRef(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown list \(raw)"))
        }
        self = ref
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    var id: String { rawValue }
    var description: String { rawValue }

    /// Liked Songs and playlists can be downloaded to the watch.
    var isDownloadable: Bool {
        if case .recentlyAdded = self { return false }
        return true
    }
}

// MARK: - Now playing (phone → watch)

struct WatchNowPlaying: Codable, Equatable {
    var songID: String?
    var title: String
    var artist: String
    var isPlaying: Bool
    var isFavorited: Bool
    var duration: Double
    /// Position when the snapshot was taken.
    var elapsed: Double
    /// Playback speed, so the watch can extrapolate progress.
    var rate: Double
    var capturedAt: Date
    var queueIndex: Int
    var queueCount: Int

    static func idle(at date: Date = Date()) -> WatchNowPlaying {
        WatchNowPlaying(
            songID: nil, title: "", artist: "", isPlaying: false, isFavorited: false,
            duration: 0, elapsed: 0, rate: 1, capturedAt: date, queueIndex: 0, queueCount: 0
        )
    }

    var hasSong: Bool { songID != nil }

    /// Extrapolated position at `date` (the watch updates progress locally
    /// between pushes instead of streaming ticks).
    func elapsed(at date: Date) -> Double {
        var position = elapsed
        if isPlaying {
            position += max(0, date.timeIntervalSince(capturedAt)) * max(rate, 0)
        }
        let upper = duration > 0 ? duration : max(position, 0)
        return min(max(position, 0), upper)
    }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return elapsed(at: date) / duration
    }

    /// Updates can arrive out of order (application context vs. message vs.
    /// reply); keep the newest.
    func isNewer(than other: WatchNowPlaying?) -> Bool {
        guard let other else { return true }
        return capturedAt >= other.capturedAt
    }
}

// MARK: - Commands (watch → phone)

struct WatchCommand: Codable, Equatable {
    enum Action: String, Codable {
        case togglePlayPause, play, pause, next, previous, seek, toggleFavorite, playSong
        /// No-op; the reply carries the current state.
        case refresh
    }

    var action: Action
    var seconds: Double?
    var songID: String?
    var list: WatchListRef?

    init(action: Action, seconds: Double? = nil, songID: String? = nil, list: WatchListRef? = nil) {
        self.action = action
        self.seconds = seconds
        self.songID = songID
        self.list = list
    }

    static func seek(to seconds: Double) -> WatchCommand { WatchCommand(action: .seek, seconds: seconds) }
    static func toggleFavorite(songID: String?) -> WatchCommand { WatchCommand(action: .toggleFavorite, songID: songID) }
    static func playSong(_ songID: String, in list: WatchListRef) -> WatchCommand {
        WatchCommand(action: .playSong, songID: songID, list: list)
    }
}

// MARK: - Browsing

struct WatchPageRequest: Codable, Equatable {
    var offset: Int
    var limit: Int
}

struct WatchSongPageRequest: Codable, Equatable {
    var list: WatchListRef
    var offset: Int
    var limit: Int
}

struct WatchSongItem: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var title: String
    var artist: String
    var duration: Double
    var isFavorited: Bool
    /// Audio file size; only filled in download manifests.
    var bytes: Int64?
    var hasArtwork: Bool
}

struct WatchPlaylistItem: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var title: String
    var songCount: Int
    /// Song whose cover stands in for the playlist.
    var artworkSongID: String?

    var list: WatchListRef { .playlist(id) }
}

struct WatchPage<Item: Codable & Equatable>: Codable, Equatable {
    var offset: Int
    var total: Int
    var items: [Item]
    var title: String?

    /// Offset of the following page, or nil at the end.
    var nextOffset: Int? {
        let end = offset + items.count
        return (!items.isEmpty && end < total) ? end : nil
    }
}

// MARK: - Artwork

struct WatchArtworkRequest: Codable, Equatable {
    var songID: String
    var maxPixel: Int
}

struct WatchArtwork: Codable, Equatable {
    var songID: String
    var maxPixel: Int
    /// nil when the song has no cover.
    var jpeg: Data?
}

// MARK: - Downloads to the watch

struct WatchManifestRequest: Codable, Equatable {
    var list: WatchListRef
}

/// The songs of a list with their file sizes, so the watch can plan a
/// download against its storage budget before anything is sent.
struct WatchDownloadManifest: Codable, Equatable {
    var list: WatchListRef
    var title: String
    var songs: [WatchSongItem]
    /// Songs in the list on the phone (may exceed `songs.count` when capped).
    var totalSongsInList: Int
}

struct WatchTransferRequest: Codable, Equatable {
    var list: WatchListRef
    var songIDs: [String]
}

struct WatchTransferAck: Codable, Equatable {
    /// Newly handed to `transferFile`.
    var queued: [String]
    /// Already transferring from an earlier request.
    var alreadyQueued: [String]
    /// Not in the list, missing on disk, or not a format the watch can play.
    var unavailable: [String]
}

struct WatchCancelTransfers: Codable, Equatable {
    var songIDs: [String]
}

/// `transferFile` metadata describing the audio file.
struct WatchFileMetadata: Codable, Equatable {
    var songID: String
    var title: String
    var artist: String
    var duration: Double
    var bytes: Int64
    var fileExtension: String
    var list: WatchListRef
}

struct WatchTransferFailure: Codable, Equatable {
    var songID: String
    var reason: String
}
