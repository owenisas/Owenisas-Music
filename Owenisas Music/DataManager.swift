import Foundation
import SwiftData
import UIKit

/// Manages syncing the file system (Documents/Songs/) with SwiftData,
/// and provides helper methods for the UI to load Song structs.
@MainActor
class DataManager: ObservableObject {
    static let shared = DataManager()

    var modelContext: ModelContext?

    // MARK: - Setup
    func configure(with context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Sync file system → SwiftData
    /// Scans Documents/Songs/ and upserts into SwiftData
    func syncFromFileSystem() {
        guard let ctx = modelContext else { return }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let songsFolder = docs.appendingPathComponent("Songs")

        // Create folder if needed
        if !fm.fileExists(atPath: songsFolder.path) {
            try? fm.createDirectory(at: songsFolder, withIntermediateDirectories: true)
        }

        guard let subfolders = try? fm.contentsOfDirectory(
            at: songsFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var foundIDs: Set<String> = []

        for folder in subfolders {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let folderName = folder.lastPathComponent
            foundIDs.insert(folderName)

            guard let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }

            let audioExts = ["mp3", "wav", "m4a", "aac", "flac"]
            let imageExts = ["jpg", "jpeg", "png", "webp"]
            let subExts = ["vtt", "srv1", "txt"]

            let audioFile = contents.first { audioExts.contains($0.pathExtension.lowercased()) }
            let coverFile = contents.first { imageExts.contains($0.pathExtension.lowercased()) }
            let subtitleFile = contents.first { subExts.contains($0.pathExtension.lowercased()) }

            guard let audio = audioFile, let cover = coverFile else { continue }

            let audioRelPath = "Songs/\(folderName)/\(audio.lastPathComponent)"
            let coverRelPath = "Songs/\(folderName)/\(cover.lastPathComponent)"
            let subtitleRelPath = subtitleFile != nil ? "Songs/\(folderName)/\(subtitleFile!.lastPathComponent)" : nil

            // Check if already exists
            let descriptor = FetchDescriptor<SongData>(predicate: #Predicate { $0.id == folderName })
            let existing = (try? ctx.fetch(descriptor))?.first

            if let song = existing {
                // Update paths if changed
                song.audioFilePath = audioRelPath
                song.coverImagePath = coverRelPath
                song.subtitleFilePath = subtitleRelPath
            } else {
                let song = SongData(
                    id: folderName,
                    title: folderName,
                    audioFilePath: audioRelPath,
                    coverImagePath: coverRelPath,
                    subtitleFilePath: subtitleRelPath
                )
                ctx.insert(song)
            }
        }

        // Remove songs whose folders were deleted
        let allDescriptor = FetchDescriptor<SongData>()
        if let allSongs = try? ctx.fetch(allDescriptor) {
            for song in allSongs {
                if !foundIDs.contains(song.id) {
                    ctx.delete(song)
                }
            }
        }

        try? ctx.save()
    }

    // MARK: - Fetch helpers
    func fetchAllSongs() -> [SongData] {
        guard let ctx = modelContext else { return [] }
        let descriptor = FetchDescriptor<SongData>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)])
        return (try? ctx.fetch(descriptor)) ?? []
    }

    func fetchAllAlbums() -> [AlbumData] {
        guard let ctx = modelContext else { return [] }
        let descriptor = FetchDescriptor<AlbumData>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)])
        return (try? ctx.fetch(descriptor)) ?? []
    }

    func fetchAllPlaylists() -> [PlaylistData] {
        guard let ctx = modelContext else { return [] }
        let descriptor = FetchDescriptor<PlaylistData>(sortBy: [SortDescriptor(\.dateCreated, order: .reverse)])
        return (try? ctx.fetch(descriptor)) ?? []
    }

    // MARK: - Playlist CRUD
    func createPlaylist(title: String) -> PlaylistData? {
        guard let ctx = modelContext else { return nil }
        let playlist = PlaylistData(title: title)
        ctx.insert(playlist)
        try? ctx.save()
        NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
        return playlist
    }

    func addSong(_ song: SongData, to playlist: PlaylistData) {
        if !playlist.songs.contains(where: { $0.id == song.id }) {
            playlist.songs.append(song)
            try? modelContext?.save()
            NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
        }
    }

    func removeSong(_ song: SongData, from playlist: PlaylistData) {
        playlist.songs.removeAll { $0.id == song.id }
        try? modelContext?.save()
        NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
    }

    func deletePlaylist(_ playlist: PlaylistData) {
        modelContext?.delete(playlist)
        try? modelContext?.save()
        NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
    }

    func renamePlaylist(_ playlist: PlaylistData, to newTitle: String) {
        playlist.title = newTitle
        try? modelContext?.save()
        NotificationCenter.default.post(name: .init("PlaylistsChanged"), object: nil)
    }

    // MARK: - Song deletion
    func deleteSong(_ song: SongData) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let songFolder = docs.appendingPathComponent("Songs").appendingPathComponent(song.id)

        // Remove from filesystem
        try? fm.removeItem(at: songFolder)

        // Remove from SwiftData
        modelContext?.delete(song)
        try? modelContext?.save()
    }

    // MARK: - Convert SongData → Song (lightweight struct for player)
    func toSong(_ data: SongData) -> Song {
        Song.from(data)
    }

    func toSongs(_ dataArray: [SongData]) -> [Song] {
        dataArray.map { Song.from($0) }
    }
}
