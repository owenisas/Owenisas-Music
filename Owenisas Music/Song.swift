import Foundation
import SwiftData

/// Resolved once: the path accessors below run for every song on every list
/// render, and `FileManager.urls(for:in:)` isn't free.
let documentsDirectoryURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

// MARK: - SwiftData Models

@Model
final class SongData {
    @Attribute(.unique) var id: String           // folder name (unique key)
    var title: String
    var artist: String
    var albumTitle: String
    var audioFilePath: String                     // relative to Documents/
    var coverImagePath: String?                   // relative to Documents/
    var subtitleFilePath: String?                 // relative to Documents/
    var duration: TimeInterval
    var trackNumber: Int
    var dateAdded: Date
    var lastPlayedDate: Date?
    var playCount: Int = 0
    var isFavorited: Bool = false
    /// Saved playback position for resuming long tracks (mixes, sets). 0 = start over.
    var playbackPosition: TimeInterval = 0

    @Relationship(inverse: \PlaylistData.songs)
    var playlists: [PlaylistData] = []

    @Relationship(inverse: \AlbumData.songs)
    var album: AlbumData?

    init(
        id: String,
        title: String,
        artist: String = "Unknown Artist",
        albumTitle: String = "Unknown Album",
        audioFilePath: String,
        coverImagePath: String? = nil,
        subtitleFilePath: String? = nil,
        duration: TimeInterval = 0,
        trackNumber: Int = 0,
        dateAdded: Date = .now,
        lastPlayedDate: Date? = nil,
        playCount: Int = 0,
        isFavorited: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.audioFilePath = audioFilePath
        self.coverImagePath = coverImagePath
        self.subtitleFilePath = subtitleFilePath
        self.duration = duration
        self.trackNumber = trackNumber
        self.dateAdded = dateAdded
        self.lastPlayedDate = lastPlayedDate
        self.playCount = playCount
        self.isFavorited = isFavorited
    }

    /// Resolve the absolute audio file URL
    var audioFileURL: URL {
        let docs = documentsDirectoryURL
        return docs.appendingPathComponent(audioFilePath)
    }

    /// Resolve the absolute cover image URL
    var coverImageURL: URL? {
        guard let path = coverImagePath, !path.isEmpty else { return nil }
        let docs = documentsDirectoryURL
        return docs.appendingPathComponent(path)
    }

    /// Resolve the absolute subtitle URL
    var subtitleFileURL: URL? {
        guard let path = subtitleFilePath else { return nil }
        let docs = documentsDirectoryURL
        return docs.appendingPathComponent(path)
    }
}

@Model
final class AlbumData {
    @Attribute(.unique) var id: String
    var title: String
    var artist: String
    var coverImagePath: String?
    var dateAdded: Date
    var songs: [SongData] = []

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String = "Unknown Artist",
        coverImagePath: String? = nil,
        dateAdded: Date = .now
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.coverImagePath = coverImagePath
        self.dateAdded = dateAdded
    }

    var coverImageURL: URL? {
        guard let path = coverImagePath else { return nil }
        let docs = documentsDirectoryURL
        return docs.appendingPathComponent(path)
    }
}

@Model
final class PlaylistData {
    @Attribute(.unique) var id: String
    var title: String
    var coverImagePath: String?
    var dateCreated: Date
    var songs: [SongData] = []
    /// User-chosen track order (song ids). SwiftData doesn't preserve the
    /// order of a to-many relationship, so drag-to-reorder never stuck.
    var songOrder: [String]?

    /// Songs in the user's order; songs added since the last reorder follow.
    var orderedSongs: [SongData] {
        songs.ordered(like: songOrder)
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        coverImagePath: String? = nil,
        dateCreated: Date = .now
    ) {
        self.id = id
        self.title = title
        self.coverImagePath = coverImagePath
        self.dateCreated = dateCreated
    }

    var coverImageURL: URL? {
        guard let path = coverImagePath else { return nil }
        let docs = documentsDirectoryURL
        return docs.appendingPathComponent(path)
    }
}

// MARK: - Stable list order

extension Array where Element == SongData {
    /// Reorder to a remembered id order. Playing a song bumps its play date /
    /// count, which yanked the tapped row to the top of "Recently Played" and
    /// "Most Played" mid-browse; screens freeze their order on appear instead.
    /// Songs not in `ids` (new since) keep their relative order at the end.
    func ordered(like ids: [String]?) -> [SongData] {
        guard let ids else { return self }
        var rank: [String: Int] = [:]
        for (i, id) in ids.enumerated() where rank[id] == nil { rank[id] = i }
        return enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? Int.max, rb = rank[b.element.id] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: - Subtitle language cache

private class SubtitleLangCacheEntry {
    let languages: [(code: String, name: String)]
    init(languages: [(code: String, name: String)]) { self.languages = languages }
}
private let _subtitleLangCache = NSCache<NSString, SubtitleLangCacheEntry>()

extension Notification.Name {
    /// Posted with the song folder path after lyric/caption files change.
    static let subtitlesChanged = Notification.Name("SubtitlesChanged")
}

// MARK: - Lightweight struct for the player (non-SwiftData)

struct Song: Identifiable, Equatable {
    let id: String
    var title: String
    var artist: String
    var albumTitle: String
    var audioFileURL: URL
    var coverImageURL: URL?
    var subtitleFileURL: URL?
    var isFavorited: Bool
    var savedPosition: TimeInterval = 0

    static func == (lhs: Song, rhs: Song) -> Bool {
        lhs.id == rhs.id
    }

    /// The folder containing this song's files
    var songFolderURL: URL? {
        audioFileURL.deletingLastPathComponent()
    }

    /// Discover all available subtitle languages by scanning the song folder for .vtt files.
    /// Returns tuples of (language code, display name) sorted alphabetically.
    /// Files named `{title}.{lang}.vtt` are recognized; plain `{title}.vtt` maps to "original".
    var availableSubtitleLanguages: [(code: String, name: String)] {
        Self.subtitleLanguagesCache(for: songFolderURL)
    }

    /// Forget the cached language list for a song folder. Call after writing
    /// new lyric/caption files, or they stay hidden until relaunch.
    static func invalidateSubtitleCache(forFolder folder: URL) {
        _subtitleLangCache.removeObject(forKey: folder.path as NSString)
        // Observers update SwiftUI state; downloads call this off-main.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .subtitlesChanged, object: folder.path)
        }
    }

    /// Cached subtitle language discovery to avoid repeated filesystem scans.
    private static func subtitleLanguagesCache(for folder: URL?) -> [(code: String, name: String)] {
        guard let folder = folder else { return [] }
        let cacheKey = folder.path as NSString
        if let cached = _subtitleLangCache.object(forKey: cacheKey) {
            return cached.languages
        }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }

        var languages: [(code: String, name: String)] = []
        for file in files where file.pathExtension.lowercased() == "vtt" {
            let stem = file.deletingPathExtension().lastPathComponent
            let parts = stem.components(separatedBy: ".")
            if parts.count >= 2, let langCode = parts.last, langCode.count <= 10 {
                if langCode == "lyrics" {
                    languages.append((code: "lyrics", name: "Lyrics ✦"))
                } else {
                    let displayName = Locale.current.localizedString(forLanguageCode: langCode) ?? langCode
                    languages.append((code: langCode, name: displayName))
                }
            } else {
                // Plain .vtt without language code
                languages.append((code: "original", name: "Original"))
            }
        }
        // Put "Lyrics ✦" first, then sort the rest
        let result = languages.sorted {
            if $0.code == "lyrics" { return true }
            if $1.code == "lyrics" { return false }
            return $0.name < $1.name
        }
        _subtitleLangCache.setObject(SubtitleLangCacheEntry(languages: result), forKey: cacheKey)
        return result
    }

    /// Get the subtitle file URL for a specific language code.
    func subtitleFileURL(for languageCode: String) -> URL? {
        guard let folder = songFolderURL else { return nil }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }

        for file in files where file.pathExtension.lowercased() == "vtt" {
            let stem = file.deletingPathExtension().lastPathComponent
            if languageCode == "original" {
                // Match plain .vtt (no language suffix)
                let parts = stem.components(separatedBy: ".")
                if parts.count < 2 || parts.last == stem {
                    return file
                }
            } else if stem.hasSuffix(".\(languageCode)") {
                return file
            }
        }
        return nil
    }

    /// Convert from SwiftData model
    static func from(_ data: SongData) -> Song {
        Song(
            id: data.id,
            title: data.title,
            artist: data.artist,
            albumTitle: data.albumTitle,
            audioFileURL: data.audioFileURL,
            coverImageURL: data.coverImageURL,
            subtitleFileURL: data.subtitleFileURL,
            isFavorited: data.isFavorited,
            savedPosition: data.playbackPosition
        )
    }
}

/// AVAudioPlayer on iOS plays AAC/MP3/etc. It does **not** play WebM/Opus.
/// A googlevideo itag-251 file saved as `.m4a` looks like a song in Library
/// and then auto-skips on play (phone, 2026-08-29).
enum PlayableLocalAudio {
    static func isPlayable(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size >= 20_000 else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        return container(of: head) != .unplayable
    }

    enum Container {
        case m4a
        case mp3
        case wav
        case flac
        case aiff
        case unplayable
    }

    static func container(of head: Data) -> Container {
        // WebM / EBML
        if head.count >= 4 && head[0] == 0x1A && head[1] == 0x45 && head[2] == 0xDF && head[3] == 0xA3 {
            return .unplayable
        }
        if head.count >= 8 {
            let ftyp = head.subdata(in: 4..<8)
            if let s = String(data: ftyp, encoding: .ascii), s == "ftyp" {
                return .m4a
            }
        }
        // Imported WAV / FLAC / AIFF (all listed as supported import formats)
        if head.count >= 4, let magic = String(data: head.prefix(4), encoding: .ascii) {
            switch magic {
            case "RIFF": return .wav
            case "fLaC": return .flac
            case "FORM": return .aiff
            default: break
            }
        }
        // ID3 or MPEG frame sync
        if head.count >= 3 {
            if head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33 { return .mp3 }
            if head[0] == 0xFF && (head[1] & 0xE0) == 0xE0 { return .mp3 }
        }
        return .unplayable
    }
}

