import SwiftUI
import UniformTypeIdentifiers

/// Portable snapshot of everything that lives only in the database —
/// playlists, likes, play history. Audio files are already plain files
/// the user can copy out of Files.app, so they are not duplicated here.
struct LibraryBackup: Codable {
    struct SongBackup: Codable {
        var id: String
        var playCount: Int
        var isFavorited: Bool
        var lastPlayedDate: Date?
        var dateAdded: Date?
        var playbackPosition: TimeInterval?
    }

    struct PlaylistBackup: Codable {
        var title: String
        var dateCreated: Date
        var songIDs: [String]
    }

    var version: Int = 1
    var exportDate: Date
    var songs: [SongBackup]
    var playlists: [PlaylistBackup]
}

struct LibraryBackupImportResult: Equatable {
    var matchedSongs: Int
    var totalSongs: Int
    var newPlaylists: Int
}

/// Minimal FileDocument wrapper so `.fileExporter` can write the backup JSON.
struct JSONBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
