import Foundation
import SwiftData

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
    var lastPlayedDate: Date?                     // Track listening history
    var isFavorited: Bool = false                // Liked songs

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
        self.isFavorited = isFavorited
    }

    /// Resolve the absolute audio file URL
    var audioFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(audioFilePath)
    }

    /// Resolve the absolute cover image URL
    var coverImageURL: URL? {
        guard let path = coverImagePath, !path.isEmpty else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(path)
    }

    /// Resolve the absolute subtitle URL
    var subtitleFileURL: URL? {
        guard let path = subtitleFilePath else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
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
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
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
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(path)
    }
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
        guard let folder = songFolderURL else { return [] }
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
        return languages.sorted {
            if $0.code == "lyrics" { return true }
            if $1.code == "lyrics" { return false }
            return $0.name < $1.name
        }
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
            isFavorited: data.isFavorited
        )
    }
}

