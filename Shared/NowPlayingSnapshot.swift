import Foundation

// Now-playing state shared between the app (writer, NowPlayingBridge) and the
// widget extension (reader). Plain Foundation so every target that compiles
// Shared/ can build it.

/// Widget / control kinds and the deep link the widgets open.
enum NowPlayingWidgetKind {
    static let nowPlaying = "OwenisasNowPlaying"
    static let playPauseControl = "com.Owenisas-Music.Widget.PlayPause"
    /// Tapping a widget outside its buttons. Routing is the app's job.
    static let openURL = URL(string: "owenisas://nowplaying")!
}

/// One small, versioned record of what is playing. Written as JSON into the
/// App Group whenever the song, play state or favourite changes; the widget
/// projects progress from `elapsed` + `updatedAt` instead of being reloaded
/// every second.
struct NowPlayingSnapshot: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var songID: String?
    var title: String
    var artist: String
    var isPlaying: Bool
    var isFavorited: Bool
    /// Seconds into the track at `updatedAt`.
    var elapsed: TimeInterval
    var duration: TimeInterval
    /// Playback speed; progress advances `playbackRate` track-seconds per second.
    var playbackRate: Double
    var updatedAt: Date
    /// File in the App Group artwork folder, nil when the song has no cover.
    var artworkFileName: String?

    init(
        songID: String?,
        title: String,
        artist: String,
        isPlaying: Bool,
        isFavorited: Bool = false,
        elapsed: TimeInterval = 0,
        duration: TimeInterval = 0,
        playbackRate: Double = 1,
        updatedAt: Date = Date(),
        artworkFileName: String? = nil
    ) {
        self.version = Self.currentVersion
        self.songID = songID
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
        self.isFavorited = isFavorited
        self.elapsed = elapsed
        self.duration = duration
        self.playbackRate = playbackRate
        self.updatedAt = updatedAt
        self.artworkFileName = artworkFileName
    }

    static func notPlaying(at date: Date = Date()) -> NowPlayingSnapshot {
        NowPlayingSnapshot(songID: nil, title: "", artist: "", isPlaying: false, updatedAt: date)
    }

    var hasSong: Bool { songID != nil }

    // MARK: Codable (tolerant: an older or newer writer must never blank the widget)

    private enum CodingKeys: String, CodingKey {
        case version, songID, title, artist, isPlaying, isFavorited
        case elapsed, duration, playbackRate, updatedAt, artworkFileName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        songID = try c.decodeIfPresent(String.self, forKey: .songID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        isFavorited = try c.decodeIfPresent(Bool.self, forKey: .isFavorited) ?? false
        elapsed = try c.decodeIfPresent(TimeInterval.self, forKey: .elapsed) ?? 0
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        artworkFileName = try c.decodeIfPresent(String.self, forKey: .artworkFileName)
    }

    // MARK: Progress

    /// Playback speed safe to divide by.
    var effectiveRate: Double {
        playbackRate.isFinite && playbackRate > 0 ? playbackRate : 1
    }

    /// `elapsed` clamped into the track.
    var clampedElapsed: TimeInterval {
        guard elapsed.isFinite else { return 0 }
        guard duration.isFinite, duration > 0 else { return max(0, elapsed) }
        return min(max(0, elapsed), duration)
    }

    /// Position at `date`, extrapolated while playing.
    func elapsed(at date: Date) -> TimeInterval {
        guard isPlaying else { return clampedElapsed }
        let projected = clampedElapsed + max(0, date.timeIntervalSince(updatedAt)) * effectiveRate
        guard duration.isFinite, duration > 0 else { return projected }
        return min(projected, duration)
    }

    /// 0...1 at `date`.
    func fractionComplete(at date: Date) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(elapsed(at: date) / duration, 0), 1)
    }

    /// Wall-clock span of the whole track at the current speed, for
    /// `ProgressView(timerInterval:)`. Nil unless playing a track of known length.
    var playbackInterval: ClosedRange<Date>? {
        guard isPlaying, duration.isFinite, duration > 0 else { return nil }
        let start = updatedAt.addingTimeInterval(-clampedElapsed / effectiveRate)
        let end = start.addingTimeInterval(duration / effectiveRate)
        return start...end
    }

    /// When the current track should finish if nothing else happens.
    var projectedEndDate: Date? { playbackInterval?.upperBound }

    /// Paused at the end of the track, as of `date`.
    func pausedAtEnd(at date: Date) -> NowPlayingSnapshot {
        var copy = self
        copy.isPlaying = false
        copy.elapsed = duration.isFinite && duration > 0 ? duration : clampedElapsed
        copy.updatedAt = date
        return copy
    }

    /// What the widget should show at `date`. A "playing" record whose track
    /// should already have ended means the app stopped updating (killed or
    /// suspended), so show it paused at the end rather than a frozen full bar.
    func resolved(at date: Date) -> NowPlayingSnapshot {
        guard let end = projectedEndDate, end <= date else { return self }
        return pausedAtEnd(at: date)
    }

    // MARK: Change detection

    /// Whether publishing `self` after `previous` changes what a widget shows.
    /// Ignores ordinary progress (the widget extrapolates it); a position that
    /// drifted by more than `driftTolerance` (seek, stall) does count.
    func needsWidgetReload(comparedTo previous: NowPlayingSnapshot?, driftTolerance: TimeInterval = 2) -> Bool {
        guard let previous else { return true }
        if songID != previous.songID
            || title != previous.title
            || artist != previous.artist
            || isPlaying != previous.isPlaying
            || isFavorited != previous.isFavorited
            || artworkFileName != previous.artworkFileName
            || abs(effectiveRate - previous.effectiveRate) > 0.001
            || abs(sanitized(duration) - sanitized(previous.duration)) > 0.5 {
            return true
        }
        guard hasSong else { return false }
        let expected = previous.elapsed(at: updatedAt)
        return abs(clampedElapsed - expected) > driftTolerance
    }

    private func sanitized(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? value : 0
    }
}

/// Reads and writes the snapshot + artwork in the App Group container.
struct NowPlayingStore {
    /// `<App Group>/NowPlaying`. Nil when the App Group is unavailable, in
    /// which case every call is a harmless no-op.
    let directory: URL?

    init(directory: URL?) {
        self.directory = directory
    }

    static let shared = NowPlayingStore(
        directory: AppGroup.containerURL?.appendingPathComponent("NowPlaying", isDirectory: true)
    )

    var snapshotURL: URL? { directory?.appendingPathComponent("snapshot.json") }
    var artworkDirectory: URL? { directory?.appendingPathComponent("Artwork", isDirectory: true) }

    func load() -> NowPlayingSnapshot {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? Self.decoder.decode(NowPlayingSnapshot.self, from: data) else {
            return .notPlaying(at: .distantPast)
        }
        return snapshot
    }

    @discardableResult
    func save(_ snapshot: NowPlayingSnapshot) -> Bool {
        guard let directory, let url = snapshotURL,
              let data = try? Self.encoder.encode(snapshot) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func artworkURL(named fileName: String?) -> URL? {
        guard let fileName, !fileName.isEmpty else { return nil }
        return artworkDirectory?.appendingPathComponent(fileName)
    }

    /// Stable, filesystem-safe artwork name for a song id (ids are folder
    /// names and can hold any character). FNV-1a, so it matches across launches.
    static func artworkFileName(forSongID songID: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in songID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "art-" + String(hash, radix: 16) + ".jpg"
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
