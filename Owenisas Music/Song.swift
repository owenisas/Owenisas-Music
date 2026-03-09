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
    var coverImagePath: String                    // relative to Documents/
    var subtitleFilePath: String?                 // relative to Documents/
    var duration: TimeInterval
    var trackNumber: Int
    var dateAdded: Date

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
        coverImagePath: String,
        subtitleFilePath: String? = nil,
        duration: TimeInterval = 0,
        trackNumber: Int = 0,
        dateAdded: Date = .now
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
    }

    /// Resolve the absolute audio file URL
    var audioFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(audioFilePath)
    }

    /// Resolve the absolute cover image URL
    var coverImageURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(coverImagePath)
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
    var coverImageURL: URL
    var subtitleFileURL: URL?

    static func == (lhs: Song, rhs: Song) -> Bool {
        lhs.id == rhs.id
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
            subtitleFileURL: data.subtitleFileURL
        )
    }
}
